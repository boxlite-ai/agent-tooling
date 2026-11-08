import { randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { cloneIdentity } from './followups.mjs';

export const QUEUE_TOOL = 'mcp__boxlite_followups__queue';
const RULE = 'Use the follow-up queue for verified unresolved findings. Check for an existing issue before recording. Route agent-tooling findings upstream. Acknowledge the exact pending revisions, including an empty list, before finishing.';
const DENIED = 'Follow-up capture requires the live root session and its clone.';
const INCOMPLETE = 'Follow-up capture incomplete. Drafts remain pending.';
const QUALIFIED_CLAUDE = '2.1.319';
const deny = () => ({
  hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: DENIED },
});

function hookAllowed(message) {
  if (message.outcome !== 'success' || (message.exit_code !== undefined && message.exit_code !== 0)) return false;
  const text = (message.stdout ?? message.output ?? '').trim();
  if (!text) return true;
  try {
    const output = JSON.parse(text);
    return output && typeof output === 'object' && !Array.isArray(output) &&
      output.decision === undefined && output.continue !== false && !output.hookSpecificOutput;
  } catch {
    return false;
  }
}

// A hook payload, never a tool argument, identifies the native root and checkout.
// The pre-tool callback inserts a one-use permit for the in-process MCP invocation.
export function createFollowupSession(queue, { sessionId }) {
  const instance = randomUUID();
  let handle;
  let prompt = instance;
  let cursor = 0;
  let acknowledged = false;
  let presentation;
  let rootResponse;
  let sealed;
  let closed = false;
  let uncertain = false;
  let init;
  let result;
  let modelMessage;
  const tools = new Set();
  const permits = new Map();
  const stopEvents = new Map();
  let wakeStop;

  const caller = () => ({ root: true, clone: queue.clone, native: sessionId, instance, prompt, cursor });
  function isRoot(input, checkPrompt = true) {
    if (input.session_id !== sessionId || input.agent_id !== undefined ||
        (checkPrompt && (prompt === instance || input.prompt_id !== prompt))) return false;
    try { return cloneIdentity(input.cwd) === queue.clone; } catch { return false; }
  }

  function work() {
    cursor += 1;
    acknowledged = false;
    presentation = undefined;
    sealed = undefined;
  }

  return {
    start(input) {
      if (!isRoot(input, false) || closed) return {};
      if (input.source === 'startup' && !handle) {
        handle = queue.start(caller());
      } else if (!handle || (input.source !== 'compact' && (input.source !== 'startup' || prompt !== instance))) {
        uncertain = true;
        return { systemMessage: 'Follow-up capture unavailable for this lifecycle.' };
      }
      return { hookSpecificOutput: {
        hookEventName: 'SessionStart',
        additionalContext: `${RULE} Call ${QUEUE_TOOL} with handle ${handle}.`,
      } };
    },

    prompt(input) {
      if (!handle || !isRoot(input, false) || !input.prompt_id || closed) return {};
      // A managed run admits one user prompt. Additional input cannot qualify the close.
      if (prompt !== instance) {
        uncertain = true;
        return { decision: 'block', reason: 'The follow-up launcher admits one prompt per run.' };
      }
      queue.prompt(caller(), handle, input.prompt_id);
      prompt = input.prompt_id;
      return {};
    },

    preTool(input) {
      const isQueue = input.tool_name === QUEUE_TOOL;
      if (!handle || closed || !isRoot(input)) {
        work();
        return isQueue ? deny() : {};
      }
      if (!input.tool_use_id || tools.has(input.tool_use_id)) {
        uncertain = true;
        return isQueue ? deny() : {};
      }
      const args = input.tool_input;
      if (!isQueue) {
        work();
        tools.add(input.tool_use_id);
        return {};
      }
      if (args?.handle !== handle || Object.hasOwn(args, 'permit') || permits.size > 0 ||
          (args.action === 'acknowledge' && tools.size > 0)) return deny();
      work();
      const permit = randomUUID();
      tools.add(input.tool_use_id);
      permits.set(permit, { args, tool: input.tool_use_id, cursor });
      return { hookSpecificOutput: {
        hookEventName: 'PreToolUse', permissionDecision: 'allow', updatedInput: { ...args, permit },
      } };
    },

    invoke({ permit, ...args }) {
      const admitted = permits.get(permit);
      permits.delete(permit);
      if (closed || !admitted || admitted.cursor !== cursor || !isDeepStrictEqual(admitted.args, args)) {
        throw new Error(DENIED);
      }
      const response = queue.capture(caller(), args);
      if (args.action === 'acknowledge') acknowledged = true;
      return response;
    },

    postTool(input) {
      if (!isRoot(input) || !tools.delete(input.tool_use_id)) {
        uncertain = true;
        return {};
      }
      for (const [permit, admission] of permits) {
        if (admission.tool === input.tool_use_id) permits.delete(permit);
      }
      return {};
    },

    async stop(input) {
      if (!handle || closed || !isRoot(input)) return {};
      // Native command hooks and SDK callbacks run concurrently. Wait for the
      // installed command gate; the callback must never replace or bypass it.
      if (!stopEvents.size) await waitForStop(() => stopEvents.size > 0, 1000);
      if (stopEvents.size === 1) {
        await waitForStop(() => stopEvents.size !== 1 || [...stopEvents.values()][0] !== null, 3_660_000);
      }
      if (stopEvents.size !== 1 || [...stopEvents.values()][0] === null) {
        uncertain = true;
        return { systemMessage: INCOMPLETE };
      }
      if ([...stopEvents.values()][0] === false || closed) return {};
      if (input.background_tasks?.length || input.session_crons?.length) uncertain = true;
      const response = !uncertain && tools.size === 0 && acknowledged && rootResponse?.id === presentation &&
        rootResponse?.text === input.last_assistant_message ? presentation : undefined;
      let outcome;
      try { outcome = queue.checkpoint(caller(), handle, response); }
      catch { outcome = 'incomplete'; }
      if (outcome === 'request') {
        return { decision: 'block',
          reason: `Check this prompt for missed follow-ups, even if the reply or queue is empty. ${RULE}` };
      }
      if (outcome === 'sealed') sealed = response;
      else {
        sealed = undefined;
        return { systemMessage: INCOMPLETE };
      }
      return {};
    },

    end(input) {
      if (handle && !closed && isRoot(input, false)) {
        closed = true;
        permits.clear();
        queue.close(caller(), handle);
      }
      return {};
    },

    invalidate() {
      uncertain = true;
      return {};
    },

    observe(message) {
      if (message.session_id !== sessionId) {
        uncertain = true;
        return;
      }
      if (message.type === 'system' && message.subtype === 'init') {
        if (init) uncertain = true;
        init = message;
      }
      if (message.type === 'stream_event' && message.parent_tool_use_id === null && message.event?.type === 'message_start') {
        modelMessage = message.event.message?.id;
        if (!modelMessage || closed || result) uncertain = true;
        if (acknowledged && !presentation) presentation = modelMessage;
        else work();
        stopEvents.clear();
      }
      if (message.type === 'assistant' && message.parent_tool_use_id === null) {
        const id = message.message?.id;
        const content = message.message?.content;
        if (id !== modelMessage || !Array.isArray(content)) {
          uncertain = true;
          return;
        }
        rootResponse = { id, text: content.filter(part => part.type === 'text').map(part => part.text).join('\n') };
      }
      if (message.type === 'system' && message.hook_event === 'Stop') {
        if (message.subtype === 'hook_started') {
          if (!message.hook_id || stopEvents.has(message.hook_id)) uncertain = true;
          stopEvents.set(message.hook_id, null);
        }
        if (message.subtype === 'hook_response') {
          if (!stopEvents.has(message.hook_id) || stopEvents.get(message.hook_id) !== null) uncertain = true;
          stopEvents.set(message.hook_id, hookAllowed(message));
        }
        wakeStop?.();
      }
      if (message.type === 'result') {
        if (result) uncertain = true;
        result = message;
      }
    },

    finish({ code, signal, streamComplete, platform }) {
      if (!handle) return 0;
      const normal = platform === 'darwin' && init?.claude_code_version === QUALIFIED_CLAUDE &&
        streamComplete === true && code === 0 && signal === null &&
        !uncertain && tools.size === 0 && permits.size === 0 &&
        result?.subtype === 'success' && result.is_error === false && result.terminal_reason === 'completed' &&
        result.result_index === 0 && result.queued_turn_count === 0 &&
        sealed && rootResponse?.id === sealed && stopEvents.size === 1 && [...stopEvents.values()][0] === true;
      // One-shot Claude can close the SDK before calling SessionEnd.
      // Only the supervisor can supply exhaustion and the child close status.
      if (normal && !closed) queue.close(caller(), handle);
      closed = true;
      permits.clear();
      return queue.finish(caller(), handle, normal ? sealed : undefined);
    },
  };

  function waitForStop(ready, timeout) {
    if (ready()) return;
    return new Promise(resolve => {
      const done = () => {
        clearTimeout(timer);
        wakeStop = undefined;
        resolve();
      };
      const timer = setTimeout(done, timeout);
      timer.unref();
      wakeStop = () => { if (ready()) done(); };
    });
  }
}
