#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { randomBytes, randomUUID } from 'node:crypto';
import { lstatSync, mkdirSync, realpathSync } from 'node:fs';
import { userInfo } from 'node:os';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { cloneIdentity, containsPath, git, openFollowupQueue } from '../.agents/lib/followups.mjs';
import { drainFollowups, githubClient, githubRepository } from '../.agents/lib/followup-publisher.mjs';
import { AGENT_ENV, checkSdk, PLUGIN, runManagedFollowups, SUDO } from '../.agents/lib/followup-claude.mjs';

const TOOLING = 'boxlite-ai/agent-tooling';

function fail(message) { throw new Error(message); }

/** Resolve existing parents while keeping missing path components for init. */
function canonicalLocation(path) {
  if (lstatSync(path, { throwIfNoEntry: false })) return realpathSync(path);
  return join(canonicalLocation(dirname(path)), basename(path));
}

/** Probe effective agent access before opening operator-owned state. */
function isolatedUser(user, cwd, stateRoot, registryRoot, executable) {
  if (process.getuid === undefined || process.getuid() === 0 || !/^[a-zA-Z_][a-zA-Z0-9_-]*$/.test(user ?? '')) {
    fail('A dedicated unprivileged agent account is required on this host');
  }
  const prefix = ['-n', '-H', '-u', user, '--'];
  const probe = (file, args) => execFileSync(SUDO, [...prefix, file, ...args], {
    cwd, env: AGENT_ENV, encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();
  const uid = Number(probe('/usr/bin/id', ['-u']));
  if (!Number.isSafeInteger(uid) || uid < 1 || uid === process.getuid()) fail('Agent account is not isolated');
  // Check effective access because filesystem ACLs can override mode bits.
  const assertPrivate = root => probe('/bin/sh', ['-c', 'test ! -r "$1" && test ! -w "$1" && test ! -x "$1"', 'sh', root]);
  for (const root of [stateRoot, registryRoot]) assertPrivate(root);
  const inspected = new Set();
  const inspect = root => {
    for (let path = root; !inspected.has(path); path = dirname(path)) {
      probe('/bin/sh', ['-c', 'test ! -w "$1"', 'sh', path]);
      inspected.add(path);
    }
  };
  for (const root of [PLUGIN, dirname(stateRoot), dirname(registryRoot), executable].filter(Boolean)) inspect(root);
  const writable = probe('/usr/bin/find', [PLUGIN, '-exec', '/bin/sh', '-c',
    'for entry do if test -w "$entry"; then printf "%s\\n" "$entry"; fi; done', 'sh', '{}', '+']);
  if (writable) fail('The agent account can modify the installed plugin');
  return { prefix, verifySdk: sdkPath => checkSdk(sdkPath, { assertPrivate, inspect }) };
}

function consumerName(cwd) {
  const profile = JSON.parse(git(cwd, 'show', 'HEAD:.agent-tooling/profile.json'));
  const origin = git(cwd, 'remote', 'get-url', 'origin');
  const slug = origin.match(/^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)([a-z0-9_.-]+\/[a-z0-9_.-]+?)(?:\.git)?\/?$/i)?.[1];
  if (profile.schemaVersion !== 1 || typeof profile.repository !== 'string' ||
      !slug || slug.toLowerCase() !== profile.repository.toLowerCase()) {
    fail('Committed consumer profile does not match the GitHub origin');
  }
  return slug;
}

async function confirm(text) {
  if (!process.stdin.isTTY || !process.stderr.isTTY) fail('Open an operator terminal to review and confirm');
  const nonce = randomBytes(5).toString('hex');
  const input = createInterface({ input: process.stdin, output: process.stderr });
  try {
    // JSON renders draft control characters inert while showing the exact Markdown.
    process.stderr.write(`${JSON.stringify(text, null, 2)}\n`);
    if (await input.question(`Type ${nonce} to confirm: `) !== nonce) fail('Confirmation did not match');
  } finally {
    input.close();
  }
}

async function readInput() {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > 64 * 1024) fail('Input is too large');
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString('utf8');
  if (!text.trim()) fail('Input is empty');
  return text;
}

/** Validate the operator boundary before dispatching a queue command. */
async function main() {
  const [stateArgument, agentUser, action, ...args] = process.argv.slice(2);
  if (!stateArgument || !agentUser || !action) fail('Usage: followups.mjs STATE_DIR AGENT_USER init|enroll|opt-out|status|history|capture|approve|release|drain|run');
  const cwd = realpathSync(git(process.cwd(), 'rev-parse', '--show-toplevel'));
  const stateRoot = resolve(stateArgument);
  const common = realpathSync(git(cwd, 'rev-parse', '--path-format=absolute', '--git-common-dir'));
  const statePath = join(canonicalLocation(dirname(stateRoot)), basename(stateRoot));
  if (containsPath(cwd, statePath) || containsPath(common, statePath)) fail('Follow-up authority must be outside the checkout and Git directory');
  const clone = cloneIdentity(cwd);
  const registryRoot = join(userInfo().homedir, '.boxlite-followups');
  const initialize = action === 'init';
  if (initialize && args.length) fail('Use init without arguments');
  if (initialize) {
    for (const root of [statePath, registryRoot]) mkdirSync(root, { mode: 0o700, recursive: true });
  }
  if (!lstatSync(statePath).isDirectory()) fail('Initialize a private follow-up directory first');
  if (action === 'run' && (!isAbsolute(args[0] ?? '') || !isAbsolute(args[1] ?? ''))) {
    fail('SDK module and Claude executable must be absolute paths');
  }
  const executable = action === 'run' ? realpathSync(args[1]) : undefined;
  const { prefix, verifySdk } = isolatedUser(agentUser, cwd, statePath, registryRoot, executable);
  const queue = openFollowupQueue(statePath, clone, { initialize, registryRoot });
  if (initialize || action === 'status') return queue.status();
  if (action === 'history') {
    if (args.length > 1 || (args.length && !/^[1-9][0-9]*$/.test(args[0]))) fail('Use history [NEXT_BEFORE]');
    return queue.history(args.length ? Number(args[0]) : null);
  }
  if (action === 'run') {
    return runManagedFollowups(queue, cwd, prefix, args[0], executable, await readInput(), { verifySdk });
  }
  if (action === 'drain') return drainFollowups(queue);
  if (action === 'opt-out') return queue.enroll(args[0], null);
  if (action === 'enroll') {
    const route = args[0];
    if (route !== 'consumer' && route !== 'tooling') fail('Choose consumer or tooling enrollment');
    const target = await githubRepository(githubClient(), route === 'tooling' ? TOOLING : consumerName(cwd));
    await confirm({ action: 'Enroll a destination for publicly approved drafts', route, target });
    return queue.enroll(route, target);
  }
  if (action === 'capture') {
    const input = JSON.parse(await readInput());
    const id = randomUUID();
    const caller = { root: true, clone, native: id, instance: id, prompt: id, cursor: 0 };
    const handle = queue.start(caller);
    try { return queue.capture(caller, { ...input, action: 'record', handle }); }
    finally { queue.finish(caller, handle, undefined); }
  }
  if (action === 'approve' || action === 'release') {
    const draft = queue.review(args[0]);
    await confirm({ action: 'Approve disclosure to anyone, even if the repository is private',
      release: action === 'release', id: draft.id, revision: draft.revision,
      target: draft.target, title: draft.title, body: draft.body });
    queue.approve(draft.id, draft.digest, action === 'release');
    return { id: draft.id, revision: draft.revision, approved: true };
  }
  fail('Unknown follow-up command');
}

try {
  const result = await main();
  if (result !== undefined) process.stdout.write(`${JSON.stringify(result)}\n`);
} catch (error) {
  process.stderr.write(`followups: ${error.message}\n`);
  process.exitCode = 1;
}
