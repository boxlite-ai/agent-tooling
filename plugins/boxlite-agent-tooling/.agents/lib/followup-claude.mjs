import { execFileSync, spawn } from 'node:child_process';
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

async function waitForClose(exit, timeout) {
  let timer;
  try {
    return await Promise.race([exit, new Promise(done => { timer = setTimeout(done, timeout); })]);
  } finally {
    clearTimeout(timer);
  }
}

function launchAgent(prefix, { command, args, cwd, signal }) {
  // Use a fresh group and keep operator credentials out of the agent environment.
  return spawn(SUDO, [...prefix, '/usr/bin/env', 'CLAUDE_CODE_ENTRYPOINT=sdk-ts', command, ...args],
    { cwd, signal, detached: true, env: AGENT_ENV, stdio: ['pipe', 'pipe', 'inherit'] });
}

async function closeAgent(child, exit, stop, timeout) {
  if (!exit) return;
  const status = await waitForClose(exit, timeout);
  if (status) return status;

  try {
    stop(child);
  } finally {
    child.stdin?.destroy();
    child.stdout?.destroy();
    child.stderr?.destroy();
    if (!await waitForClose(exit, timeout)) child.unref();
  }
  throw new Error('Managed Claude did not close within the deadline');
}

export async function runManagedFollowups(queue, cwd, prefix, sdkFile, claudeFile, prompt, {
  launch, github, verifySdk, closeTimeout = 5000,
} = {}) {
  if (!isAbsolute(sdkFile ?? '') || !isAbsolute(claudeFile ?? '')) {
    throw new Error('SDK module and Claude executable must be absolute paths');
  }
  const sdkPath = realpathSync(sdkFile);
  verifySdk?.(sdkPath);
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
          child = launch ? launch(options) : launchAgent(prefix, options);
          exit = new Promise(done => {
            child.once('close', (code, exitSignal) => done({ code, signal: exitSignal }));
            // Abort can emit an error before the process and pipes have closed.
            child.on('error', () => {});
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
    let status;
    try {
      status = await closeAgent(child, exit, process => {
        if (!launch && process.pid) {
          try {
            execFileSync(SUDO, [...prefix, '/bin/kill', '-KILL', '--', `-${process.pid}`],
              { cwd, env: AGENT_ENV, stdio: 'ignore', timeout: 1000 });
          } finally {
            process.kill('SIGKILL');
          }
        } else process.kill('SIGKILL');
      }, closeTimeout);
    } finally {
      released = session.finish({
        ...(status ?? { code: null, signal: null }), streamComplete, platform: process.platform,
      });
    }
  }
  return released ? { released, ...await drainFollowups(queue, github) } : { released };
}
