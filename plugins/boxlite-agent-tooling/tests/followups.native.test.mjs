import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { runManagedFollowups, SUDO } from '../.agents/lib/followup-claude.mjs';
import { drainFollowups } from '../.agents/lib/followup-publisher.mjs';
import { QUEUE_TOOL } from '../.agents/lib/followup-session.mjs';
import { cloneIdentity, openFollowupQueue } from '../.agents/lib/followups.mjs';

const sdk = process.env.BOXLITE_FOLLOWUP_SDK;
const claude = process.env.BOXLITE_FOLLOWUP_CLAUDE;
const native = { skip: process.platform !== 'darwin' || !sdk || !claude, timeout: 30_000 };
const target = { id: 'R_fixture', name: 'boxlite-ai/agent-tooling' };
const titles = ['Approved draft', 'Approved draft with lost response', 'Unapproved draft'];

function sendModelResponse(res, model, turn, block) {
  const tool = block.type === 'tool_use';
  const message = { id: `msg_fixture_${turn}`, type: 'message', role: 'assistant', model, content: [],
    stop_reason: null, stop_sequence: null, usage: { input_tokens: 10, output_tokens: 0 } };
  res.writeHead(200, { 'content-type': 'text/event-stream' });
  const emit = (type, data) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`);
  emit('message_start', { message });
  emit('content_block_start', { index: 0, content_block: tool ? { ...block, input: {} } : { type: 'text', text: '' } });
  emit('content_block_delta', { index: 0, delta: tool
    ? { type: 'input_json_delta', partial_json: JSON.stringify(block.input) }
    : { type: 'text_delta', text: block.text } });
  emit('content_block_stop', { index: 0 });
  emit('message_delta', { delta: { stop_reason: tool ? 'tool_use' : 'end_turn', stop_sequence: null }, usage: { output_tokens: 5 } });
  emit('message_stop', {});
  res.end();
}

/** Drive the pinned Claude executable with a loopback model and controlled launcher exit. */
async function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'boxlite-native-followups-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const cwd = join(root, 'repo');
  execFileSync('git', ['init', '-q', cwd]);
  execFileSync('git', ['-C', cwd, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
    '-c', 'core.hooksPath=/dev/null', 'commit', '-q', '--allow-empty', '-m', 'Fixture']);
  const queue = openFollowupQueue(join(root, 'state'), cloneIdentity(cwd), { initialize: true });
  queue.enroll('tooling', target);
  let turn = 0;
  let modelFailure;
  const server = createServer(async (req, res) => {
    try {
      if (req.url !== '/v1/messages' && !req.url.startsWith('/v1/messages?')) {
        res.writeHead(200, { 'content-type': 'application/json' }).end('{}');
        return;
      }
      req.setEncoding('utf8');
      let request = '';
      for await (const chunk of req) request += chunk;
      const { model } = JSON.parse(request);
      const handle = request.match(/with handle ([0-9a-f-]{36})/)?.[1];
      assert.ok(handle, 'SessionStart advertised the live handle');
      turn += 1;
      let block;
      if (turn === 1) {
        block = { type: 'text', text: '## TL;DR\n\nI have no further observations.\n\n## Details' };
      } else if (turn <= 4) {
        const title = titles[turn - 2];
        block = { type: 'tool_use', name: QUEUE_TOOL, id: `toolu_fixture_${turn}`, input: {
          handle, action: 'record', repository: 'example/project', operation: title, failure: 'fixture failure',
          route: 'tooling', title, body: 'Synthetic draft body.', evidence: 'Synthetic model fixture.',
        } };
      } else if (turn === 5) {
        const drafts = queue.status();
        assert.deepEqual(drafts.map(draft => draft.title), titles);
        for (const draft of drafts.slice(0, 2)) queue.approve(draft.id, queue.review(draft.id).digest, false);
        block = { type: 'tool_use', name: QUEUE_TOOL, id: 'toolu_fixture_ack', input: {
          handle, action: 'acknowledge', drafts: drafts.map(({ id, revision }) => ({ id, revision })),
        } };
      } else {
        assert.equal(turn, 6, 'Stop requests at most one capture pass');
        assert.match(request, /acknowledged/);
        block = { type: 'text', text: '## TL;DR\n\nThe drafts are in the queue.\n\n## Details' };
      }
      sendModelResponse(res, model, turn, block);
    } catch (error) {
      modelFailure = error;
      res.writeHead(400).end('Invalid fixture request');
    }
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => {
    server.closeAllConnections();
    server.close();
    assert.ifError(modelFailure);
  });
  const run = (github, exitCode, closeTimeout) => runManagedFollowups(queue, cwd, [], sdk, claude, 'Check for missed follow-ups.', {
    github, closeTimeout,
    launch: ({ command, args, env, signal }) => {
      const options = { cwd, signal: signal ? AbortSignal.any([signal, t.signal]) : t.signal,
        stdio: ['pipe', 'pipe', 'inherit'], env: { ...env, CLAUDE_CONFIG_DIR: join(root, 'claude'),
          CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', VERDICT_CLASSIFIER_CMD: 'false', VERDICT_AUDITOR_CMD: 'false',
          ANTHROPIC_BASE_URL: `http://127.0.0.1:${server.address().port}`,
          ANTHROPIC_API_KEY: 'fixture-token', ANTHROPIC_AUTH_TOKEN: '' } };
      if (closeTimeout) {
        return spawn(process.execPath, ['-e', `
          const { spawnSync } = require('node:child_process');
          const [command, ...args] = process.argv.slice(1);
          spawnSync(command, args, { stdio: 'inherit' });
          setInterval(() => {}, 1000);
        `, command, ...args], options);
      }
      return exitCode === undefined ? spawn(command, args, options)
        : spawn('/bin/sh', ['-c', 'code=$1; shift; "$@"; exit "$code"', 'fixture', String(exitCode), command, ...args], options);
    },
  });
  return { queue, run };
}

test('native clean exit files approved revisions and reconciles a lost create without resending', native, async t => {
  const { queue, run } = await fixture(t);
  const issues = [];
  const github = async (query, variables) => {
    if (query.includes('viewer')) return { viewer: { id: 'U_fixture' } };
    if (query.includes('createIssue')) {
      const { repositoryId, title, body } = variables.input;
      assert.equal(repositoryId, target.id);
      assert.match(body, /<!-- boxlite-followup:[0-9a-f-]+ -->$/);
      const number = issues.length + 1;
      const issue = { id: `I_${number}`, url: `https://github.com/boxlite-ai/agent-tooling/issues/${number}`,
        title, body, repository: { id: repositoryId }, author: { id: 'U_fixture' } };
      issues.push(issue);
      if (title === titles[1]) throw new Error('Fixture committed the issue and lost the response');
      return { createIssue: { issue } };
    }
    assert.equal(variables.id, target.id);
    return { node: { id: target.id, issues: { nodes: issues, pageInfo: { hasNextPage: false } } } };
  };
  assert.deepEqual(await run(github), { released: 3, requests: 3 });
  assert.deepEqual(queue.status().map(draft => draft.status), ['filed', 'pending', 'pending']);
  assert.deepEqual(issues.map(issue => issue.title), titles.slice(0, 2));
  t.mock.timers.enable({ apis: ['Date'], now: Date.now() });
  t.mock.timers.tick(60_001);
  assert.deepEqual(await drainFollowups(queue, github), { requests: 1 });
  assert.deepEqual(await drainFollowups(queue, github), { requests: 0 });
  assert.equal(issues.length, 2);
  assert.equal(queue.status()[1].url, issues[1].url);
  assert.equal(queue.status()[2].status, 'pending');
});

test('native completed result with a failed launcher exit leaves approved drafts pending', native, async t => {
  const { queue, run } = await fixture(t);
  let requests = 0;
  await assert.rejects(run(async () => { requests += 1; }, 17), /exited with code 17/);
  assert.equal(requests, 0);
  assert.deepEqual(queue.status().map(draft => [draft.approved, draft.released]),
    [[true, false], [true, false], [false, false]]);
});


test('native final result with an open process holds approved drafts', native, async t => {
  const { queue, run } = await fixture(t);
  let requests = 0;
  await assert.rejects(run(async () => { requests += 1; }, undefined, 1000), /did not close within the deadline/);
  assert.equal(requests, 0);
  assert.deepEqual(queue.status().map(draft => [draft.approved, draft.released]),
    [[true, false], [true, false], [false, false]]);
});

const cliRoot = process.env.BOXLITE_FOLLOWUP_CLI_ROOT;
const cliAgent = process.env.BOXLITE_FOLLOWUP_CLI_AGENT;
const isolated = { skip: process.platform !== 'darwin' || !cliRoot || !cliAgent, timeout: 30_000 };
test('the default launcher kills descendants when stdout remains open after the result', isolated, async t => {
  const root = mkdtempSync(join(cliRoot, 'default-close-'));
  chmodSync(root, 0o755);
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const cwd = join(root, 'repo');
  execFileSync('git', ['init', '-q', cwd]);
  const queue = openFollowupQueue(join(root, 'state'), cloneIdentity(cwd), { initialize: true });
  const wrapper = join(root, 'agent.cjs');
  const pidFile = join(root, 'agent-pids.json');
  const prefix = ['-n', '-H', '-u', cliAgent, '--'];
  const signal = (name, pid) => spawnSync(SUDO, [...prefix, '/bin/kill', name, String(pid)],
    { stdio: 'ignore', timeout: 3000 }).status === 0;

  writeFileSync(wrapper, `#!${process.execPath}
    const { spawn } = require('node:child_process');
    const worker = spawn(process.execPath, ['-e', ${JSON.stringify(
      "process.on('SIGTERM', () => {}); console.log('ready'); setTimeout(() => process.exit(), 15000);"
    )}]);
    worker.stdout.once('data', () => console.log(JSON.stringify([process.pid, worker.pid])));
    process.on('SIGTERM', () => {});
    setTimeout(() => process.exit(), 16000).unref();
  `, { mode: 0o755 });

  const sdkFile = join(root, 'sdk.mjs');
  mkdirSync(join(root, 'node_modules', 'zod'), { recursive: true });
  writeFileSync(join(root, 'node_modules', 'zod', 'index.js'), `
    const schema = { optional() { return this; }, int() { return this; }, max() { return this; } };
    exports.z = new Proxy({}, { get: () => () => schema });
  `);
  writeFileSync(join(root, 'package.json'), JSON.stringify({
    name: '@anthropic-ai/claude-agent-sdk', version: '0.3.319',
  }));
  writeFileSync(sdkFile, `
    import { once } from 'node:events';
    import { writeFileSync } from 'node:fs';
    export const tool = () => {};
    export const createSdkMcpServer = () => {};
    export async function* query({ options }) {
      const child = options.spawnClaudeCodeProcess({ command: options.pathToClaudeCodeExecutable, args: [], cwd: options.cwd });
      const [pids] = await once(child.stdout, 'data');
      writeFileSync(${JSON.stringify(pidFile)}, pids);
      yield { type: 'result', session_id: options.sessionId, subtype: 'success' };
      await once(child.stdout, 'close');
    }
  `);

  try {
    await assert.rejects(runManagedFollowups(queue, cwd, prefix, sdkFile, wrapper, 'Fixture', { closeTimeout: 500 }),
      /did not close within the deadline/);
    const [agent, descendant] = JSON.parse(readFileSync(pidFile, 'utf8'));
    assert.ok(Number.isSafeInteger(agent) && agent > 1);
    assert.ok(Number.isSafeInteger(descendant) && descendant > 1 && descendant !== agent);
    for (let poll = 0; poll < 20 && signal('-0', descendant); poll++) await delay(100);
    assert.equal(signal('-0', descendant), false, 'descendant remains alive after the shutdown deadline');
  } finally {
    if (existsSync(pidFile)) {
      for (const pid of JSON.parse(readFileSync(pidFile, 'utf8'))) {
        if (Number.isSafeInteger(pid) && pid > 1) signal('-KILL', pid);
      }
    }
  }
});
