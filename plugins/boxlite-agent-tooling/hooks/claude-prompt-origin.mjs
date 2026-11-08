export function register(on) {
  const pending = new Map();

  on("prompt.submit", async ($, event, next) => {
    const { origin, text } = event;
    if (origin?.kind !== "task-notification" || origin.subkind ||
        typeof text !== "string" || text.length > 8192) {
      return next(event);
    }
    const lines = text.split("\n");
    if (lines.length !== 7 || lines[0] !== "<task-notification>" ||
        !lines[5].startsWith("<summary>Background command ") ||
        lines[6] !== "</task-notification>") {
      return next(event);
    }

    let nonce;
    try {
      nonce = crypto.randomUUID();
    } catch {
      return next(event);
    }
    const session = await $.session.id();
    if (!session || next.signal?.aborted) return next(event);

    // The classic hook has no dispatch ID. A one-use tag binds its input to
    // this continuation even when another prompt has identical original text.
    const tagged = `${text}\n[boxlite-bash-notice:${nonce}]`;
    const clear = () => pending.delete(tagged);
    pending.set(tagged, { session, text });
    try {
      next.signal?.addEventListener("abort", clear, { once: true });
      return await next({ ...event, text: tagged });
    } finally {
      clear();
      next.signal?.removeEventListener("abort", clear);
    }
  });

  on("classic.UserPromptSubmit", (_$, event, next) => {
    const { boxlite_verified_bash_notice: _unverified, ...input } = event;
    const dispatch = pending.get(input.prompt);
    if (!dispatch || dispatch.session !== input.session_id) return next(input);
    pending.delete(input.prompt);
    return next({ ...input, prompt: dispatch.text, boxlite_verified_bash_notice: dispatch.text });
  });
}
