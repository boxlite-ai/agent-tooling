// Contract tests for the OMP host bridge: tool-name mapping, route tables,
// payload synthesis, and stop-outcome mapping. Pure functions only; the shell
// suites exercise the real gates themselves.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import {
  CLAUDE_TOOL_NAMES,
  canonicalToolName,
  evidenceModeFromProbe,
  mapStopOutcome,
  preToolUsePayload,
  routesForTool,
  stopPayload,
  textOfContent,
  toolResponseFrom,
} from '../../hooks/omp-bridge.mjs';

const BASE = { hook_event_name: 'PreToolUse', session_id: 's1', transcript_path: '/t.jsonl', cwd: '/r' };

test('canonical tool names cover the generic-manifest matchers', () => {
  assert.equal(canonicalToolName('bash'), 'Bash');
  assert.equal(canonicalToolName('Bash'), 'Bash');
  assert.equal(canonicalToolName('ast_edit'), 'Edit');
  assert.equal(canonicalToolName('write'), 'Write');
  assert.equal(canonicalToolName('websearch'), 'WebSearch');
  assert.equal(canonicalToolName('taskstop'), 'TaskStop');
  assert.equal(canonicalToolName('greeting_extension'), null);
  assert.equal(canonicalToolName(undefined), null);
  assert.ok(Object.values(CLAUDE_TOOL_NAMES).every(name => typeof name === 'string' && name !== ''));
});

test('bash routes mirror the generic manifest order', () => {
  const routes = routesForTool('Bash').map(route => route.script);
  assert.deepEqual(routes, [
    'preflight-design-worker.sh',
    'preflight-commit-push.sh',
    'preflight-pr-review.sh',
    'audit-deadline.sh',
    'audit-privacy.sh',
  ]);
  const launcher = routesForTool('Bash')[1];
  assert.deepEqual(launcher.args, ['--launcher-pid', String(process.pid)]);
});

test('edit tools run the design gate first, inspect tools never do', () => {
  assert.deepEqual(routesForTool('Write').map(route => route.script),
    ['preflight-design-doc.sh', 'audit-deadline.sh', 'audit-privacy.sh']);
  assert.deepEqual(routesForTool('Read').map(route => route.script),
    ['audit-deadline.sh', 'audit-privacy.sh']);
  assert.deepEqual(routesForTool('Glob'), []);
});

test('OMP path fields feed the design gate target extraction', () => {
  const fromPath = preToolUsePayload(BASE, 'Write', { path: '/r/a.rs', content: 'x' });
  assert.equal(fromPath.tool_input.file_path, '/r/a.rs');
  const fromPaths = preToolUsePayload(BASE, 'Edit', { paths: ['/r/b.rs', '/r/c.rs'], ops: [] });
  assert.equal(fromPath.tool_name, 'Write');
  assert.equal(fromPaths.tool_input.file_path, '/r/b.rs');
  const explicit = preToolUsePayload(BASE, 'Edit', { file_path: '/r/d.rs', path: '/r/ignored' });
  assert.equal(explicit.tool_input.file_path, '/r/d.rs');
  const blank = preToolUsePayload(BASE, 'Edit', { path: '' });
  assert.equal(blank.tool_input.file_path, undefined);
  assert.equal(preToolUsePayload(BASE, 'Glob', { path: '/r' }).tool_input.file_path, undefined);
});

test('bash tool responses synthesize the post-hook shape', () => {
  const failed = toolResponseFrom({ details: { exitCode: 3 }, isError: true, content: [{ type: 'text', text: 'out' }] });
  assert.deepEqual(failed, { exit_code: 3, stdout: 'out', stderr: '' });
  const plain = toolResponseFrom({ isError: false, content: [{ type: 'text', text: 'a' }, { type: 'text', text: 'b' }] });
  assert.equal(plain.exit_code, 0);
  assert.equal(plain.stdout, 'a\nb');
  assert.equal(toolResponseFrom({ isError: true, content: [] }).exit_code, 1);
});

test('text extraction keeps only text blocks', () => {
  assert.equal(textOfContent([{ type: 'text', text: 'x' }, { type: 'image' }, { type: 'text', text: 'y' }]), 'x\ny');
  assert.equal(textOfContent(undefined), '');
  assert.equal(textOfContent('not an array'), '');
});

test('stop payloads switch evidence by containment capability', () => {
  const event = { stop_hook_active: false, last_assistant_message: { content: [{ type: 'text', text: 'Done.' }] } };
  const base = { ...BASE, transcript_path: '/session.jsonl' };
  const transcript = stopPayload(base, event, 'transcript');
  assert.equal(transcript.transcript_path, '/session.jsonl');
  assert.equal(transcript.last_assistant_message, 'Done.');
  const payload = stopPayload(base, event, 'payload');
  // An unusable transcript path returns a false-truncated snapshot that forces
  // an audit on every settle, so restricted hosts send the reply only.
  assert.equal(payload.transcript_path, '');
  const empty = stopPayload(base, { stop_hook_active: true, last_assistant_message: { content: [] } }, 'payload');
  assert.equal('last_assistant_message' in empty, false);
  assert.equal(empty.stop_hook_active, true);
  assert.equal(evidenceModeFromProbe('linux-pid-namespace'), 'transcript');
  assert.equal(evidenceModeFromProbe(''), 'payload');
});

test('stop outcome mapping follows the gate contract', () => {
  const blocked = mapStopOutcome({ code: 2, timedOut: false, stdout: '', stderr: 'design: no PASS\n' });
  assert.deepEqual(blocked, { decision: 'block', reason: 'design: no PASS' });
  const json = mapStopOutcome({ code: 0, timedOut: false, stdout: '{"decision":"block","reason":"continue design"}\n', stderr: '' });
  assert.deepEqual(json, { decision: 'block', reason: 'continue design' });
  assert.equal(mapStopOutcome({ code: 0, timedOut: false, stdout: '', stderr: '' }), undefined);
  const timedOut = mapStopOutcome({ code: -1, timedOut: true, stdout: '', stderr: '' });
  assert.equal(timedOut.decision, 'block');
  assert.match(timedOut.reason, /25(000|,000)|budget/);
});
