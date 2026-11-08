import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { cloneIdentity, openFollowupQueue } from '../.agents/lib/followups.mjs';
import { createFollowupSession, QUEUE_TOOL } from '../.agents/lib/followup-session.mjs';
import { sessionHooks } from '../.agents/lib/followup-claude.mjs';
import { drainFollowups } from '../.agents/lib/followup-publisher.mjs';

const GATE = fileURLToPath(new URL('../.agents/hooks/stop-gate.sh', import.meta.url));
const DRAFT = {
  action: 'record', repository: 'example/project', operation: 'load config', failure: 'missing default',
  route: 'tooling', title: 'Load the default on an empty config',
  body: 'A verified empty config loses the default.', evidence: 'Observed in the config fixture.',
};
const DESTINATION = { id: 'R_original', name: 'boxlite-ai/agent-tooling' };

function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'boxlite-followups-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const repo = join(directory, 'repo');
  const other = join(directory, 'other');
  execFileSync('git', ['init', '-q', repo]);
  execFileSync('git', ['-C', repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
    '-c', 'core.hooksPath=/dev/null', 'commit', '-q', '--allow-empty', '-m', 'Fixture']);
  execFileSync('git', ['clone', '-q', '--no-hardlinks', repo, other]);
  const origin = 'https://github.com/example/project.git';
  execFileSync('git', ['-C', repo, 'remote', 'add', 'origin', origin]);
  execFileSync('git', ['-C', other, 'remote', 'set-url', 'origin', origin]);
  const state = join(directory, 'state');
  return {
    repo, other, state,
    queue: openFollowupQueue(state, cloneIdentity(repo), { initialize: true }),
    otherQueue: openFollowupQueue(state, cloneIdentity(other), { initialize: true }),
  };
}

function stopGate(input) {
  const result = spawnSync('bash', [GATE], {
    cwd: input.cwd, input: JSON.stringify({ hook_event_name: 'Stop', stop_hook_active: false, ...input }),
    encoding: 'utf8',
    env: { ...process.env, VERDICT_CLASSIFIER_CMD: 'false' },
  });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim() ? JSON.parse(result.stdout) : {};
}

async function managed(queue, cwd, sessionId = 'native-root', runStop = stopGate) {
  const adapter = createFollowupSession(queue, { sessionId });
  const hooks = sessionHooks(adapter);
  const native = { session_id: sessionId, cwd, prompt_id: 'prompt-1' };
  const hook = (name, data = {}) => hooks[name][0].hooks[0]({ ...native, ...data });
  const start = await hook('SessionStart', { source: 'startup' });
  const handle = start.hookSpecificOutput.additionalContext.match(/handle ([0-9a-f-]+)\.$/)[1];
  assert.match(start.hookSpecificOutput.additionalContext, new RegExp(QUEUE_TOOL));
  await hook('UserPromptSubmit');
  let toolIndex = 0;
  const pre = (input, caller = {}) => hook('PreToolUse', {
    tool_name: QUEUE_TOOL, tool_input: { handle, ...input }, tool_use_id: `tool-${++toolIndex}`, ...caller,
  });
  const capture = async input => {
    const admitted = await pre(input);
    const result = adapter.invoke(admitted.hookSpecificOutput.updatedInput);
    await hook('PostToolUse', { tool_use_id: `tool-${toolIndex}` });
    return result;
  };
  const observe = message => adapter.observe({ session_id: sessionId, ...message });
  observe({ type: 'system', subtype: 'init', claude_code_version: '2.1.319' });
  const presentation = (id, text) => {
    observe({ type: 'stream_event', parent_tool_use_id: null, event: { type: 'message_start', message: { id } } });
    observe({ type: 'assistant', parent_tool_use_id: null, message: { id, content: [{ type: 'text', text }] } });
  };
  let stopIndex = 0;
  const stop = async (input = {}) => {
    const hook_id = `gate-${++stopIndex}`;
    observe({ type: 'system', subtype: 'hook_started', hook_event: 'Stop', hook_id });
    const checkpoint = hook('Stop', input);
    const verdict = await runStop({ ...native, ...input });
    observe({ type: 'system', subtype: 'hook_response', hook_event: 'Stop', hook_id,
      outcome: 'success', exit_code: 0, stdout: JSON.stringify(verdict) });
    const capture = await checkpoint;
    return verdict.decision === undefined ? capture : verdict;
  };
  const finish = async (outcome = {}, sessionEnd = true, exit = {}) => {
    observe({ type: 'result', subtype: 'success', terminal_reason: 'completed', is_error: false,
      result_index: 0, queued_turn_count: 0, ...outcome });
    if (sessionEnd) await hook('SessionEnd');
    return adapter.finish({ code: 0, signal: null, streamComplete: true, platform: 'darwin', ...exit });
  };
  return { hook, pre, capture, presentation, stop, finish, handle, adapter };
}

test('the live handle rejects another session, subagent and clone, then works after compaction', async t => {
  const { repo, other, queue, otherQueue } = fixture(t);
  const root = await managed(queue, repo);
  for (const caller of [{ session_id: 'another-session' }, { agent_id: 'child' }, { cwd: other }]) {
    const denied = await root.pre(DRAFT, caller);
    assert.equal(denied.hookSpecificOutput.permissionDecision, 'deny');
    assert.equal(denied.hookSpecificOutput.updatedInput, undefined);
  }
  assert.throws(() => root.adapter.invoke({ ...DRAFT, handle: root.handle, permit: 'copied' }), /live root session/);
  assert.deepEqual(queue.status(), []);
  assert.deepEqual(otherQueue.status(), []);

  const compacted = await root.hook('SessionStart', { source: 'compact' });
  assert.match(compacted.hookSpecificOutput.additionalContext, new RegExp(root.handle));
  const written = await root.capture(DRAFT);
  assert.equal(queue.status()[0].id, written.id);
  assert.deepEqual(otherQueue.status(), []);
});

test('Stop recovers an omitted draft and acknowledges its saved revision exactly once', async t => {
  const { repo, queue } = fixture(t);
  const root = await managed(queue, repo);
  root.presentation('unrelated', '');
  const first = await root.stop({ last_assistant_message: '' });
  assert.equal(first.decision, 'block');
  assert.match(first.reason, /missed follow-ups/);
  root.presentation('repeated', '');
  const repeated = await root.stop({ last_assistant_message: '' });
  assert.equal(repeated.decision, undefined);
  assert.match(repeated.systemMessage, /incomplete/);
  assert.deepEqual(queue.status(), []);

  // The simulated model continuation invokes the production queue tool.
  const { id, revision } = await root.capture(DRAFT);
  const pending = await root.capture({ action: 'list' });
  assert.deepEqual(pending.drafts, [{ id, revision }]);
  const receipt = await root.capture({ action: 'acknowledge', drafts: pending.drafts });
  assert.deepEqual(receipt.acknowledged, [{ id, revision }]);
  root.presentation('final', 'Saved the follow-up.');
  const allowed = await root.stop({ last_assistant_message: 'Saved the follow-up.', stop_hook_active: true });
  assert.equal(allowed.decision, undefined);
  assert.doesNotMatch(allowed.systemMessage ?? '', /incomplete/);
  assert.equal(queue.status()[0].released, false);
  assert.equal(await root.finish(), 1);
  assert.equal(queue.status()[0].id, id);
  assert.equal(queue.status()[0].revision, revision);
  assert.equal(queue.status()[0].released, true);
});

test('a block from the existing Stop gate leaves the capture request available', async t => {
  const { repo, queue } = fixture(t);
  let blocked = true;
  const root = await managed(queue, repo, 'native-root', async () => blocked ? { decision: 'block', reason: 'Existing gate' } : {});
  root.presentation('initial', '');
  assert.equal((await root.stop()).reason, 'Existing gate');
  blocked = false;
  root.presentation('continued', '');
  assert.match((await root.stop()).reason, /missed follow-ups/);
});

test('later model work, failed host close and old revisions cannot release a draft', async t => {
  const { repo, queue } = fixture(t);
  const root = await managed(queue, repo, 'native-root', async () => ({}));
  const { id, revision } = await root.capture(DRAFT);
  await assert.rejects(root.capture({ action: 'acknowledge', drafts: [] }), /exact pending/);
  // A rejected tool call still completes natively.
  await root.hook('PostToolUseFailure', { tool_use_id: 'tool-2' });
  await root.capture({ action: 'acknowledge', drafts: [{ id, revision }] });
  root.presentation('final', 'Saved.');
  await root.stop({ last_assistant_message: 'Saved.' });
  root.presentation('continued', 'More work.');
  assert.equal(await root.finish({ terminal_reason: 'interrupted' }), 0);
  assert.equal(queue.status()[0].released, false);

  const restarted = await managed(queue, repo);
  assert.notEqual(root.handle, restarted.handle);
  const stale = await restarted.pre({ ...DRAFT, handle: root.handle });
  assert.equal(stale.hookSpecificOutput.permissionDecision, 'deny');
  assert.equal(queue.status()[0].revision, revision);
});

test('a clean one-shot exit releases a sealed draft when the SDK omits SessionEnd', async t => {
  const { repo, queue } = fixture(t);
  const root = await managed(queue, repo, 'native-root', async () => ({}));
  const { id, revision } = await root.capture(DRAFT);
  await root.capture({ action: 'acknowledge', drafts: [{ id, revision }] });
  root.presentation('last', 'The draft is in the queue.');
  assert.deepEqual(await root.stop({ last_assistant_message: 'The draft is in the queue.' }), {});
  assert.equal(await root.finish({}, false), 1);
  assert.equal(queue.status()[0].released, true);
});

test('an incomplete one-shot close holds a sealed draft even with SessionEnd', async t => {
  const cases = [
    ['SDK did not exhaust', {}, { streamComplete: false }],
    ['child exit was nonzero', {}, { code: 143 }],
    ['child exited on a signal', {}, { code: null, signal: 'SIGTERM' }],
    ['host profile is unqualified', {}, { platform: 'linux' }],
    ['root result left queued input', { queued_turn_count: 1 }, {}],
    ['root result sequence has a gap', { result_index: 1 }, {}],
  ];
  for (const [reason, outcome, exit] of cases) {
    await t.test(reason, async caseTest => {
      const { repo, queue } = fixture(caseTest);
      const root = await managed(queue, repo, 'native-root', async () => ({}));
      const { id, revision } = await root.capture(DRAFT);
      await root.capture({ action: 'acknowledge', drafts: [{ id, revision }] });
      root.presentation('last', 'The draft is in the queue.');
      assert.deepEqual(await root.stop({ last_assistant_message: 'The draft is in the queue.' }), {});
      assert.equal(await root.finish(outcome, true, exit), 0);
      assert.equal(queue.status()[0].released, false);
    });
  }
});

function issueFor(input) {
  return { id: 'I_1', url: 'https://github.com/boxlite-ai/agent-tooling/issues/1', body: input.body,
    author: { id: 'U_original' }, repository: { id: input.repositoryId } };
}

test('a lost create holds later revisions and reconciles a closed issue with the original author', async t => {
  const { repo, queue } = fixture(t);
  t.mock.timers.enable({ apis: ['Date'], now: 1000 });
  queue.enroll('tooling', DESTINATION);
  const root = await managed(queue, repo);
  const draft = await root.capture(DRAFT);
  const first = queue.review(draft.id);
  queue.approve(draft.id, first.digest, true);
  let mutationCount = 0;
  let created;
  await drainFollowups(queue, async (query, variables) => {
    if (query.includes('viewer')) return { viewer: { id: 'U_original' } };
    mutationCount += 1;
    created = issueFor(variables.input);
    assert.throws(() => queue.status(), /locked/);
    throw new Error('GitHub committed but the response was lost');
  });
  assert.equal(mutationCount, 1);
  const restarted = await managed(queue, repo, 'second-session');
  const revised = await restarted.capture({ ...DRAFT, title: 'Preserve the empty-config default' });
  assert.equal(revised.id, draft.id);
  assert.ok(revised.revision > draft.revision);
  assert.throws(() => queue.approve(draft.id, first.digest, true), /changed during review/);
  queue.approve(draft.id, queue.review(draft.id).digest, true);
  t.mock.timers.tick(60_000);
  let pageCount = 0;
  await drainFollowups(queue, async (query, variables) => {
    assert.match(query, /OPEN,CLOSED/);
    assert.equal(variables.id, 'R_original');
    pageCount += 1;
    if (pageCount === 1) {
      assert.equal(variables.cursor, null);
      return { node: { id: 'R_original', issues: { nodes: [], pageInfo: { hasNextPage: true, endCursor: 'page-2' } } } };
    }
    assert.equal(variables.cursor, 'page-2');
    return { node: { id: 'R_original', issues: { nodes: [created], pageInfo: { hasNextPage: false } } } };
  });
  assert.equal(pageCount, 2);
  assert.equal(queue.status()[0].url, created.url);
  assert.equal(queue.status()[0].status, 'filed');
  assert.equal(mutationCount, 1);
});

test('a proven unsent request waits for backoff and checks the current approval before retrying', async t => {
  const { repo, queue } = fixture(t);
  t.mock.timers.enable({ apis: ['Date'], now: 1000 });
  queue.enroll('tooling', DESTINATION);
  const root = await managed(queue, repo);
  const { id } = await root.capture(DRAFT);
  queue.approve(id, queue.review(id).digest, true);
  let attempts = 0;
  const client = async (query, variables) => {
    if (query.includes('viewer')) return { viewer: { id: 'U_original' } };
    assert.match(query, /mutation/);
    attempts += 1;
    if (attempts === 1) throw Object.assign(new Error('TLS handshake failed'), { provenUnsent: true });
    return { createIssue: { issue: issueFor(variables.input) } };
  };
  await drainFollowups(queue, client);
  assert.equal(queue.status()[0].attempt.status, 'unsent');
  assert.deepEqual(await drainFollowups(queue, client), { requests: 0 });
  const restarted = await managed(queue, repo, 'second-session');
  await restarted.capture({ ...DRAFT, title: 'Preserve the empty-config default' });
  t.mock.timers.tick(60_000);
  assert.deepEqual(await drainFollowups(queue, client), { requests: 0 });
  queue.approve(id, queue.review(id).digest, true);
  await drainFollowups(queue, client);
  assert.equal(attempts, 2);
  assert.equal(queue.status()[0].status, 'filed');
});
