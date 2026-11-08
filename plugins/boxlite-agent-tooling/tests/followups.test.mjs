import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, realpathSync, renameSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { cloneIdentity, openFollowupQueue } from '../.agents/lib/followups.mjs';
import { createFollowupSession, QUEUE_TOOL } from '../.agents/lib/followup-session.mjs';
import { checkSdk, runManagedFollowups, sessionHooks } from '../.agents/lib/followup-claude.mjs';
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

test('linked worktrees cannot initialize a second attempt journal for the same clone', t => {
  const { repo, other } = fixture(t);
  const root = dirname(repo);
  const linked = join(root, 'linked');
  const registryRoot = join(root, 'registry');
  const first = join(root, 'operator-one');
  const second = join(root, 'operator-two');
  execFileSync('git', ['-C', repo, '-c', 'core.hooksPath=/dev/null', 'worktree', 'add', '-q', '--detach', linked]);
  const clone = cloneIdentity(repo);
  const linkedClone = cloneIdentity(linked);
  assert.equal(linkedClone, clone);

  openFollowupQueue(first, clone, { initialize: true, registryRoot });
  assert.deepEqual(openFollowupQueue(first, linkedClone, { registryRoot }).status(), []);
  assert.throws(() => openFollowupQueue(second, linkedClone, { initialize: true, registryRoot }),
    /Clone already uses another follow-up state directory/);
  assert.deepEqual(openFollowupQueue(second, cloneIdentity(other), { initialize: true, registryRoot }).status(), []);
});

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
  assert.match((await root.stop({ last_assistant_message: 'More work.' })).reason, /missed follow-ups/);
  assert.equal(await root.finish(), 0);
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
    return { node: { id: 'R_original', issues: { nodes: [
      { ...created, id: 'I_wrong_author', author: { id: 'U_wrong' } },
      { ...created, id: 'I_wrong_target', repository: { id: 'R_wrong' } },
      created,
    ], pageInfo: { hasNextPage: false } } } };
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


test('a renamed checkout keeps its journal and draft identity', t => {
  const { repo, state, queue } = fixture(t);
  const caller = { root: true, clone: queue.clone, native: 'old', instance: 'old', prompt: 'old', cursor: 0 };
  const handle = queue.start(caller);
  const draft = queue.capture(caller, { ...DRAFT, handle });
  const moved = join(dirname(repo), 'renamed');
  renameSync(repo, moved);
  const reopened = openFollowupQueue(state, cloneIdentity(moved));
  assert.equal(reopened.status()[0]?.id, draft.id);
});

test('starting a supervisor fences handles left by a dead process', t => {
  const { state, queue } = fixture(t);
  const module = new URL('../.agents/lib/followups.mjs', import.meta.url).href;
  const old = { root: true, clone: queue.clone, native: 'abandoned', instance: 'abandoned', prompt: 'old', cursor: 0 };
  const handle = execFileSync(process.execPath, ['--input-type=module', '-e',
    `import { openFollowupQueue } from ${JSON.stringify(module)};
    const queue = openFollowupQueue(process.argv[1], process.argv[2]);
    console.log(queue.start(JSON.parse(process.argv[3])));`,
    state, queue.clone, JSON.stringify(old)], { encoding: 'utf8' }).trim();
  const live = { ...old, native: 'live' };
  const liveHandle = queue.start(live);
  assert.throws(() => queue.capture(old, { action: 'list', handle }), /live root session/);
  assert.deepEqual(queue.capture(live, { action: 'list', handle: liveHandle }), { drafts: [] });
});

function approveDraft(queue, operation) {
  const caller = { root: true, clone: queue.clone, native: 'owner', instance: 'owner', prompt: 'owner', cursor: 0 };
  const handle = queue.start(caller);
  const draft = queue.capture(caller, { ...DRAFT, operation, handle });
  queue.approve(draft.id, queue.review(draft.id).digest, true);
  return draft;
}

test('an oversized reconciliation page retries a smaller read without creating again', async t => {
  const { queue } = fixture(t);
  t.mock.timers.enable({ apis: ['Date'], now: 1000 });
  queue.enroll('tooling', DESTINATION);
  approveDraft(queue, 'oversized page');
  let issue;
  await drainFollowups(queue, async (query, variables) => {
    if (query.includes('viewer')) return { viewer: { id: 'U_original' } };
    issue = issueFor(variables.input);
    throw new Error('GitHub committed but the response was lost');
  });
  t.mock.timers.tick(60_000);
  const reads = [];
  await drainFollowups(queue, async (query, variables) => {
    assert.match(query, /OPEN,CLOSED/);
    reads.push([variables.cursor, variables.size]);
    if (reads.length === 1) throw Object.assign(new Error('Response limit'), { responseTooLarge: true });
    return { node: { id: 'R_original', issues: { nodes: [issue], pageInfo: { hasNextPage: false } } } };
  });
  assert.deepEqual(reads, [[null, 50], [null, 25]]);
  assert.equal(queue.status()[0].status, 'filed');
});

test('the next drain gives a waiting draft a turn after a full read budget', async t => {
  const { queue } = fixture(t);
  t.mock.timers.enable({ apis: ['Date'], now: 1000 });
  queue.enroll('tooling', DESTINATION);
  for (let index = 0; index < 11; index++) {
    approveDraft(queue, `operation ${index}`);
    await drainFollowups(queue, async query => {
      if (query.includes('viewer')) return { viewer: { id: 'U_original' } };
      throw new Error('GitHub response was lost');
    });
  }
  t.mock.timers.tick(60_000);
  const reads = [];
  const github = async (query, variables) => {
    assert.match(query, /OPEN,CLOSED/);
    reads.push(variables.cursor);
    return { node: { id: 'R_original', issues: { nodes: [],
      pageInfo: { hasNextPage: true, endCursor: `page-${reads.length}` } } } };
  };
  await drainFollowups(queue, github);
  assert.deepEqual(reads, Array(10).fill(null));
  await drainFollowups(queue, github);
  assert.equal(reads[10], null);
});


test('retiring a draft removes it from the live queue and preserves deduplication', t => {
  const { queue } = fixture(t);
  const caller = { root: true, clone: queue.clone, native: 'owner', instance: 'owner', prompt: 'owner', cursor: 0 };
  const handle = queue.start(caller);
  const draft = queue.capture(caller, { ...DRAFT, handle });
  queue.capture(caller, { action: 'resolve', handle, id: draft.id, revision: draft.revision });
  assert.equal(queue.status()[0].status, 'resolved');
  assert.deepEqual(queue.capture(caller, { ...DRAFT, handle }), { ...draft, status: 'resolved' });
  assert.equal(queue.publish(state => Object.keys(state.drafts).length), 0);
});

test('the SDK trust policy rejects unsafe installations before evaluation', { skip: process.platform === 'win32' }, async t => {
  const { repo, queue } = fixture(t);
  const install = join(dirname(repo), 'private-install');
  const modules = join(install, 'node_modules');
  const sdk = join(modules, '@anthropic-ai', 'claude-agent-sdk', 'sdk.mjs');
  mkdirSync(dirname(sdk), { recursive: true });
  writeFileSync(join(dirname(sdk), 'package.json'), JSON.stringify({
    name: '@anthropic-ai/claude-agent-sdk', version: '0.3.319',
  }));
  writeFileSync(sdk, "throw new Error('SDK code executed');");
  const previousNodePath = process.env.NODE_PATH;
  t.after(() => {
    if (previousNodePath === undefined) delete process.env.NODE_PATH;
    else process.env.NODE_PATH = previousNodePath;
  });
  let agentCanWrite = false;
  const run = () => runManagedFollowups(queue, repo, [], sdk, process.execPath, 'Fixture', {
    verifySdk: path => checkSdk(path, {
      assertPrivate: root => {
        assert.equal(root, realpathSync(install));
        if (agentCanWrite) throw new Error('Agent account can access SDK installation');
      },
      inspect: root => assert.equal(root, realpathSync(install)),
    }),
  });

  process.env.NODE_PATH = dirname(repo);
  await assert.rejects(run(), /NODE_PATH unset/);
  delete process.env.NODE_PATH;

  agentCanWrite = true;
  await assert.rejects(run(), /Agent account can access SDK installation/);
  agentCanWrite = false;

  const dependency = join(modules, 'external');
  symlinkSync(repo, dependency);
  await assert.rejects(run(), /links outside the private npm installation/);
  unlinkSync(dependency);

  mkdirSync(join(dirname(repo), 'node_modules'));
  await assert.rejects(run(), /outside other npm trees/);
});

function fixtureSdk(repo, queryBody) {
  const root = dirname(repo);
  const sdk = join(root, 'sdk.mjs');
  mkdirSync(join(root, 'node_modules', 'zod'), { recursive: true });
  writeFileSync(join(root, 'node_modules', 'zod', 'index.js'), `
    const schema = { optional() { return this; }, int() { return this; }, max() { return this; } };
    exports.z = new Proxy({}, { get: () => () => schema });
  `);
  writeFileSync(join(root, 'package.json'), JSON.stringify({
    name: '@anthropic-ai/claude-agent-sdk', version: '0.3.319',
  }));
  writeFileSync(sdk, `
    export const tool = () => {};
    export const createSdkMcpServer = () => {};
    export async function* query({ options }) {
      ${queryBody}
    }
  `);
  return sdk;
}

test('an unfinished child that ignores TERM is killed before the supervisor returns', async t => {
  const { repo, queue } = fixture(t);
  const sdk = fixtureSdk(repo, `
    const abort = new AbortController();
    const child = options.spawnClaudeCodeProcess({ signal: abort.signal });
    await new Promise(resolve => child.stdout.once('data', resolve));
    abort.abort();
  `);
  let child;
  const run = runManagedFollowups(queue, repo, [], sdk, process.execPath, 'Fixture', {
    launch({ signal }) {
      child = spawn(process.execPath, ['-e',
        "process.on('SIGTERM', () => {}); console.log('ready'); setInterval(() => {}, 1000);"], { signal });
      t.after(() => child.kill('SIGKILL'));
      return child;
    },
    closeTimeout: 250,
  });
  await assert.rejects(run, /did not close within the deadline/);
  assert.equal(child.signalCode, 'SIGKILL');
});


test('a final root result starts the deadline while the SDK still waits for stdout', async t => {
  const { repo, queue } = fixture(t);
  const sdk = fixtureSdk(repo, `
    const child = options.spawnClaudeCodeProcess({});
    await new Promise(resolve => child.stdout.once('data', resolve));
    yield { type: 'result', session_id: options.sessionId, subtype: 'success', terminal_reason: 'completed' };
    await new Promise(resolve => child.stdout.once('close', resolve));
  `);
  let child;
  let limit;
  let githubCalls = 0;
  const run = runManagedFollowups(queue, repo, [], sdk, process.execPath, 'Fixture', {
    launch() {
      child = spawn(process.execPath, ['-e',
        "process.on('SIGTERM', () => {}); console.log('ready'); setInterval(() => {}, 1000);"]);
      t.after(() => child.kill('SIGKILL'));
      return child;
    },
    github() { githubCalls += 1; },
    closeTimeout: 250,
  });
  try {
    const fixtureLimit = new Promise((_, reject) => {
      limit = setTimeout(() => reject(new Error('Fixture stdout stayed open after the result')), 1500);
    });
    await assert.rejects(Promise.race([run, fixtureLimit]), /did not close within the deadline/);
    assert.equal(child.signalCode, 'SIGKILL');
    assert.equal(githubCalls, 0);
  } finally {
    clearTimeout(limit);
  }
});

test('a missing nested state path under an alias to the checkout is rejected before initialization', { skip: process.platform === 'win32' }, t => {
  const { repo } = fixture(t);
  const alias = join(dirname(repo), 'alias');
  symlinkSync(repo, alias);
  const cli = fileURLToPath(new URL('../scripts/followups.mjs', import.meta.url));
  const result = spawnSync(process.execPath, [cli, join(alias, 'not-created', 'state'), 'agent', 'init'],
    { cwd: repo, encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /authority must be outside the checkout/);
});

test('a full capture queue still has room to approve and send an accepted draft', async t => {
  const { queue } = fixture(t);
  queue.enroll('tooling', DESTINATION);
  const caller = { root: true, clone: queue.clone, native: 'owner', instance: 'owner', prompt: 'owner', cursor: 0 };
  const handle = queue.start(caller);
  const first = queue.capture(caller, { ...DRAFT, handle });
  const overhead = queue.publish(state => {
    const record = state.drafts[first.id];
    return Buffer.byteLength(JSON.stringify({ [record.id]: record })) - 2 -
      Buffer.byteLength(DRAFT.body) - Buffer.byteLength(record.evidence) + 1;
  });
  for (let index = 0; ; index++) {
    const bytes = queue.publish(state => Buffer.byteLength(JSON.stringify(state)));
    const available = 8 * 1024 * 1024 - bytes - overhead;
    if (available < 2) break;
    const size = Math.min(16384, available - 1);
    try {
      queue.capture(caller, { ...DRAFT, handle, operation: `fill queue ${index}`, body: 'x'.repeat(size),
        evidence: 'x'.repeat(Math.min(8192, available - size)) });
    } catch (error) {
      assert.match(error.message, /Follow-up (state|queue) is full/);
      break;
    }
  }
  assert.throws(() => queue.capture(caller, { ...DRAFT, handle, operation: 'one more draft',
    body: 'x'.repeat(16384), evidence: 'x'.repeat(8192) }), /Follow-up (state|queue) is full/);
  queue.approve(first.id, queue.review(first.id).digest, true);
  await drainFollowups(queue, async (query, variables) => query.includes('viewer')
    ? { viewer: { id: 'U_original' } }
    : { createIssue: { issue: issueFor(variables.input) } });
  assert.equal(queue.status().find(draft => draft.id === first.id)?.status, 'filed');
});


test('a path-keyed journal keeps its approval after migration and checkout rename', t => {
  const { repo } = fixture(t);
  const root = join(dirname(repo), 'legacy-state');
  const registryRoot = join(dirname(repo), 'legacy-registry');
  const legacyClone = cloneIdentity(repo, { legacy: true });
  const legacy = openFollowupQueue(root, legacyClone, { initialize: true, registryRoot });
  legacy.enroll('tooling', DESTINATION);
  const draft = approveDraft(legacy, 'legacy fixture');
  const clone = cloneIdentity(repo);
  openFollowupQueue(root, clone, { legacyClone, registryRoot });
  const renamed = join(dirname(repo), 'renamed');
  renameSync(repo, renamed);
  const [stored] = openFollowupQueue(root, cloneIdentity(renamed), { registryRoot }).status();
  assert.equal(stored.id, draft.id);
  assert.equal(stored.approved, true);
  assert.equal(stored.released, true);
});


test('a renamed legacy clone cannot create another journal before recovery', t => {
  const { repo } = fixture(t);
  const root = join(dirname(repo), 'legacy-state');
  const registryRoot = join(dirname(repo), 'legacy-registry');
  const oldCommon = execFileSync('git', ['-C', repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'],
    { encoding: 'utf8' }).trim();
  const legacyClone = cloneIdentity(repo, { legacy: true });
  const legacy = openFollowupQueue(root, legacyClone, { initialize: true, registryRoot });
  legacy.enroll('tooling', DESTINATION);
  const draft = approveDraft(legacy, 'legacy rename');
  const registry = new DatabaseSync(join(registryRoot, 'roots.sqlite'));
  try { registry.prepare('DELETE FROM journal_keys WHERE clone = ?').run(legacyClone); }
  finally { registry.close(); }

  const renamed = join(dirname(repo), 'renamed');
  renameSync(repo, renamed);
  const clone = cloneIdentity(renamed);
  assert.throws(() => openFollowupQueue(root, clone, {
    initialize: true, registryRoot, legacyClone: cloneIdentity(renamed, { legacy: true }),
  }), /previous Git common directory/);
  assert.throws(() => openFollowupQueue(root, clone, {
    initialize: true, registryRoot, requireLegacy: true,
    legacyClone: cloneIdentity(renamed, { legacyPath: join(dirname(repo), 'wrong', '.git') }),
  }), /Legacy follow-up journal was not found/);
  const recovered = openFollowupQueue(root, clone, {
    initialize: true, registryRoot, requireLegacy: true, legacyClone: cloneIdentity(renamed, { legacyPath: oldCommon }),
  });
  assert.equal(recovered.status()[0].id, draft.id);
  assert.equal(recovered.status()[0].approved, true);
  assert.equal(recovered.status()[0].released, true);
});

test('upgrading the journal removes ownerless handles and preserves live sessions and attempts', async t => {
  const { queue, state } = fixture(t);
  queue.enroll('tooling', DESTINATION);
  const draft = approveDraft(queue, 'ambiguous legacy create');
  await drainFollowups(queue, async query => {
    if (query.includes('viewer')) return { viewer: { id: 'U_original' } };
    throw new Error('Lost create response');
  });
  const old = { root: true, clone: queue.clone, native: 'ownerless', instance: 'old', prompt: 'old', cursor: 0 };
  const abandoned = queue.start(old);
  const live = { ...old, native: 'live' };
  const liveHandle = queue.start(live);
  const file = join(state, queue.clone, 'queue.sqlite');
  const db = new DatabaseSync(file);
  try {
    const prior = JSON.parse(db.prepare('SELECT document FROM queue WHERE id = 1').get().document);
    prior.version = 1;
    delete prior.sessions[abandoned].owner;
    db.prepare('UPDATE queue SET document = ? WHERE id = 1').run(JSON.stringify(prior));
  } finally { db.close(); }

  const next = openFollowupQueue(state, queue.clone);
  assert.throws(() => next.capture(old, { action: 'list', handle: abandoned }), /live root session/);
  assert.deepEqual(next.capture(live, { action: 'list', handle: liveHandle }), { drafts: [] });
  assert.equal(next.status()[0].id, draft.id);
  assert.equal(next.status()[0].attempt.status, 'pending');
  assert.equal(next.publish(state => state.version), 2);
});

test('status bounds completed history and older pages retain deduplication', t => {
  const { queue } = fixture(t);
  const caller = { root: true, clone: queue.clone, native: 'archive', instance: 'archive', prompt: 'archive', cursor: 0 };
  const handle = queue.start(caller);
  const record = index => queue.capture(caller, { ...DRAFT, handle, operation: `history ${index}` });
  const completed = Array.from({ length: 52 }, (_, index) => {
    const draft = record(index);
    queue.capture(caller, { action: 'resolve', handle, id: draft.id, revision: draft.revision });
    return draft.id;
  });
  const active = record(52);
  assert.deepEqual(queue.status().map(draft => draft.id), [...completed.slice(-50), active.id]);
  const recent = queue.history();
  assert.deepEqual(recent.drafts.map(draft => draft.id), completed.slice(-50).reverse());
  const oldest = queue.history(recent.nextBefore);
  assert.deepEqual(oldest.drafts.map(draft => draft.id), completed.slice(0, 2).reverse());
  assert.equal(oldest.nextBefore, null);
  assert.equal(record(0).status, 'resolved');
  assert.equal(record(0).id, completed[0]);
});
