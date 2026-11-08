import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFileSync, realpathSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createFollowupSession, QUEUE_TOOL } from './followup-session.mjs';
import { drainFollowups } from './followup-publisher.mjs';

export const PLUGIN = realpathSync(fileURLToPath(new URL('../..', import.meta.url)));
export const SDK_VERSION = '0.3.319';
export const SUDO = '/usr/bin/sudo';
export const AGENT_ENV = { PATH: '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin' };

export function queueToolFor(session, tool, z) {
  return tool('queue', 'Record, resolve, list, or acknowledge local follow-up drafts.', {
    handle: z.string(), action: z.enum(['record', 'resolve', 'list', 'acknowledge']), permit: z.string().optional(),
    repository: z.string().optional(), operation: z.string().optional(), failure: z.string().optional(),
    route: z.enum(['tooling', 'consumer']).optional(), title: z.string().optional(), body: z.string().optional(),
    evidence: z.string().optional(), id: z.string().optional(), revision: z.number().int().optional(),
    url: z.string().optional(),
    drafts: z.array(z.object({ id: z.string(), revision: z.number().int() })).max(2048).optional(),
  }, async args => {
    try {
      const result = session.invoke(args);
      return { content: [{ type: 'text', text: JSON.stringify(result) }] };
    } catch (error) {
      return { isError: true, content: [{ type: 'text', text: error.message }] };
    }
  });
}

export function sessionHooks(session) {
  return {
    SessionStart: [{ hooks: [async input => session.start(input)] }],
    UserPromptSubmit: [{ hooks: [async input => session.prompt(input)] }],
    PreToolUse: [{ hooks: [async input => session.preTool(input)] }],
    PostToolUse: [{ hooks: [async input => session.postTool(input)] }],
    PostToolUseFailure: [{ hooks: [async input => session.postTool(input)] }],
    SubagentStart: [{ hooks: [async () => session.invalidate()] }],
    ConfigChange: [{ hooks: [async () => session.invalidate()] }],
    Stop: [{ hooks: [async input => session.stop(input)], timeout: 3660 }],
    SessionEnd: [{ hooks: [async input => session.end(input)], timeout: 1 }],
  };
}

export function startupSettings(session, sessionId, cwd) {
  // SessionStart is a command hook in one-shot mode. The handle conveys no
  // authority until a matching SDK UserPromptSubmit and PreToolUse arrive.
  const output = JSON.stringify(session.start({ session_id: sessionId, cwd, source: 'startup' }));
  const quoted = "'" + output.replaceAll("'", "'\\''") + "'";
  return { hooks: { SessionStart: [{ matcher: 'startup|compact', hooks: [
    { type: 'command', command: `printf '%s\\n' ${quoted}` },
  ] }] } };
}

export async function runManagedFollowups(queue, cwd, prefix, sdkFile, claudeFile, prompt, {
  launch = ({ command, args, cwd: childCwd, signal }) =>
    // Keep operator credentials out of the agent account's environment.
    spawn(SUDO, [...prefix, '/usr/bin/env', 'CLAUDE_CODE_ENTRYPOINT=sdk-ts', command, ...args],
      { cwd: childCwd, signal, env: AGENT_ENV, stdio: ['pipe', 'pipe', 'inherit'] }),
  github,
} = {}) {
  if (!isAbsolute(sdkFile ?? '') || !isAbsolute(claudeFile ?? '')) {
    throw new Error('SDK module and Claude executable must be absolute paths');
  }
  const sdkPath = realpathSync(sdkFile);
  const sdkPackage = JSON.parse(readFileSync(join(dirname(sdkPath), 'package.json'), 'utf8'));
  if (sdkPackage.name !== '@anthropic-ai/claude-agent-sdk' || sdkPackage.version !== SDK_VERSION) {
    throw new Error(`Use Claude Agent SDK ${SDK_VERSION} for managed follow-ups`);
  }
  const { query, tool, createSdkMcpServer } = await import(pathToFileURL(sdkPath).href);
  const { z } = createRequire(sdkPath)('zod');
  const sessionId = randomUUID();
  const session = createFollowupSession(queue, { sessionId });
  let child;
  let exit;
  let streamComplete = false;
  let released = 0;
  try {
    const stream = query({
      prompt,
      options: {
        cwd, sessionId, pathToClaudeCodeExecutable: claudeFile,
        plugins: [{ type: 'local', path: PLUGIN }], strictMcpConfig: true, settingSources: [],
        settings: startupSettings(session, sessionId, cwd),
        includeHookEvents: true, includePartialMessages: true, allowedTools: [QUEUE_TOOL],
        mcpServers: { boxlite_followups: createSdkMcpServer({ name: 'boxlite_followups', tools: [queueToolFor(session, tool, z)] }) },
        hooks: sessionHooks(session),
        spawnClaudeCodeProcess: options => {
          if (exit) throw new Error('Expected one supervised Claude process');
          child = launch(options);
          exit = new Promise(done => {
            child.once('close', (code, exitSignal) => done({ code, signal: exitSignal }));
            child.once('error', () => done({ code: null, signal: null }));
          });
          return child;
        },
      },
    });
    for await (const message of stream) {
      session.observe(message);
      if (message.type === 'assistant' && message.parent_tool_use_id === null) {
        for (const part of message.message.content) if (part.type === 'text') process.stdout.write(`${part.text}\n`);
      }
    }
    streamComplete = true;
  } finally {
    let timer;
    const unknown = { code: null, signal: null };
    const timeout = new Promise(done => { timer = setTimeout(() => done(unknown), 5000); });
    const status = exit ? await Promise.race([exit, timeout]) : unknown;
    clearTimeout(timer);
    if (status === unknown) child?.kill();
    released = session.finish({ ...status, streamComplete, platform: process.platform });
  }
  return released ? { released, ...await drainFollowups(queue, github) } : { released };
}
