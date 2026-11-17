// OMP (oh-my-pi) host bridge.
//
// OMP loads this module through package.json "omp.extensions" and rebinds it in
// every session, subagents included. Each handler maps an OMP event onto the
// generic manifest's route (hooks/generic-hooks.json, unknown host) and runs the
// same shell scripts: JSON payload on stdin, exit 2 blocks. The bridge itself
// adds no state and authors no judgments; scripts keep their own contracts.
//
// Spawned commands receive a Claude-shaped payload with BOXLITE_HOOK_HOST=omp
// (which routes as unknown), PLUGIN_ROOT, and CLAUDE_PROJECT_DIR. OMP caps a
// session_stop handler at 30 seconds with no user setting, so the stop route
// enforces its own shorter budget and maps an overrun to an explicit block:
// an over-long verdict check fails closed instead of silently settling.
//
// Unwired by design (documented in hooks/README.md): SubagentStart/SubagentStop
// native-auditor ownership, StopFailure recovery, asyncRewake, and OMP's
// before_agent_start refusal (OMP cannot reject a prompt; the gate reply is
// delivered as a displayed message instead).

import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export const PLUGIN_ROOT = fileURLToPath(new URL("..", import.meta.url));
const HOOKS_DIR = join(PLUGIN_ROOT, ".agents", "hooks");
const SCRIPTS_DIR = join(PLUGIN_ROOT, "scripts");

const STOP_TIMEOUT_MS = Number(process.env.BOXLITE_OMP_STOP_TIMEOUT_MS) || 25_000;

/** OMP tool names (lowercase) to the capitalized names gate scripts match. */
export const CLAUDE_TOOL_NAMES = {
	bash: "Bash",
	read: "Read",
	edit: "Edit",
	write: "Write",
	glob: "Glob",
	grep: "Grep",
	webfetch: "WebFetch",
	websearch: "WebSearch",
	taskstop: "TaskStop",
	ast_edit: "Edit",
	notebookedit: "NotebookEdit",
	multiedit: "MultiEdit",
	apply_patch: "apply_patch",
};

export function canonicalToolName(toolName) {
	return CLAUDE_TOOL_NAMES[String(toolName ?? "").toLowerCase()] ?? null;
}

const EDIT_TOOLS = new Set(["Write", "Edit", "MultiEdit", "NotebookEdit", "apply_patch"]);
const INSPECT_TOOLS = new Set(["Read", "WebFetch", "WebSearch", "TaskStop"]);

/** Routes for one canonical tool, in generic-manifest order. Null script: not wired on OMP. */
export function routesForTool(canon) {
	if (canon === "Bash") {
		return [
			{ hook: "PreToolUse", script: "preflight-design-worker.sh", timeoutMs: 10_120 },
			{ hook: "PreToolUse", script: "preflight-commit-push.sh", timeoutMs: 600_000, args: ["--launcher-pid", String(process.pid)] },
			{ hook: "PreToolUse", script: "preflight-pr-review.sh", timeoutMs: 600_000 },
			{ hook: "PreToolUse", script: "audit-deadline.sh", timeoutMs: 30_000 },
			{ hook: "PreToolUse", script: "audit-privacy.sh", timeoutMs: 30_000 },
		];
	}
	if (EDIT_TOOLS.has(canon)) {
		return [
			{ hook: "PreToolUse", script: "preflight-design-doc.sh", timeoutMs: 45_000 },
			{ hook: "PreToolUse", script: "audit-deadline.sh", timeoutMs: 30_000 },
			{ hook: "PreToolUse", script: "audit-privacy.sh", timeoutMs: 30_000 },
		];
	}
	if (INSPECT_TOOLS.has(canon)) {
		return [
			{ hook: "PreToolUse", script: "audit-deadline.sh", timeoutMs: 30_000 },
			{ hook: "PreToolUse", script: "audit-privacy.sh", timeoutMs: 30_000 },
		];
	}
	return [];
}

// ── Payload builders ──────────────────────────────────────────────────────────

export function basePayload(ctx, hookEventName) {
	return {
		hook_event_name: hookEventName,
		session_id: ctx?.sessionManager?.getSessionId?.() ?? "",
		transcript_path: ctx?.sessionManager?.getSessionFile?.() ?? "",
		cwd: ctx?.cwd ?? process.cwd(),
	};
}

export function preToolUsePayload(base, canon, input) {
	// OMP edit/write carry `path` and ast_edit carries `paths[]`; the design gate
	// extracts targets from `file_path`/`notebook_path`, so copy the first path
	// across (globs land as-is and fail scope closed in the script).
	const toolInput = { ...(input ?? {}) };
	if ((canon === "Edit" || canon === "Write") && toolInput.file_path === undefined) {
		const firstPath = toolInput.path ?? toolInput.paths?.[0];
		if (typeof firstPath === "string" && firstPath !== "") toolInput.file_path = firstPath;
	}
	if (canon === "NotebookEdit" && toolInput.notebook_path === undefined && typeof toolInput.path === "string") {
		toolInput.notebook_path = toolInput.path;
	}
	return { ...base, tool_name: canon, tool_input: toolInput };
}

/** Text of an OMP content block array; the only part post scripts and Stop read. */
export function textOfContent(content) {
	if (!Array.isArray(content)) return "";
	return content
		.filter(block => block?.type === "text" && typeof block.text === "string")
		.map(block => block.text)
		.join("\n");
}

export function toolResponseFrom(event) {
	return {
		// OMP bash details carry exitCode only on failure; content text is the
		// combined output the post scripts grep.
		exit_code: event?.details?.exitCode ?? (event?.isError ? 1 : 0),
		stdout: textOfContent(event?.content),
		stderr: "",
	};
}

export function stopPayload(base, event, evidenceMode) {
	const payload = {
		...base,
		hook_event_name: "Stop",
		stop_hook_active: event?.stop_hook_active === true,
	};
	const reply = textOfContent(event?.last_assistant_message?.content);
	// Omit when empty: an explicit empty string reads as intentional silence and
	// would skip the reply checks.
	if (reply !== "") payload.last_assistant_message = reply;
	// Transcript mode: the gate stages the session file through the extractor for
	// full-turn audit evidence. Payload mode: the gate's transcript parser cannot
	// read OMP session JSONL and the extractor override needs OS containment, so
	// an unusable transcript path would come back as a false-truncated snapshot
	// that forces an audit on every settle — send the final reply only.
	if (evidenceMode !== "transcript") payload.transcript_path = "";
	return payload;
}

// ── Evidence-mode probe ───────────────────────────────────────────────────────
// Mirrors the verdict check's bounded_capture_prepare_override_isolation: an
// explicit extractor override runs only inside OS process containment, so the
// bridge offers transcript evidence only where that containment works.

let containmentProbed = false;
let containmentBackend = "";

/** Pure decision over a probe result, for contract tests. */
export function evidenceModeFromProbe(backend) {
	return backend ? "transcript" : "payload";
}

export function probeContainment() {
	if (containmentProbed) return containmentBackend;
	containmentProbed = true;
	containmentBackend = "";
	const kernel = process.platform === "darwin" ? "Darwin" : process.platform === "linux" ? "Linux" : "";
	if (kernel === "Darwin" && existsSync("/usr/bin/sandbox-exec") && existsSync("/usr/bin/perl")) {
		const test = spawnSync("/usr/bin/sandbox-exec", [
			"-p", "(version 1) (allow default) (deny process-fork)",
			"/usr/bin/perl", "-e", "my $child = fork(); exit(defined($child) ? 1 : 0);",
		], { stdio: "ignore", timeout: 10_000 });
		if (test.status === 0) containmentBackend = "darwin-sandbox";
	} else if (kernel === "Linux") {
		const unshare = ["/usr/bin/unshare", "/bin/unshare"].find(path => existsSync(path));
		if (unshare) {
			const test = spawnSync(unshare, [
				"--user", "--map-root-user", "--pid", "--fork", "--kill-child=KILL",
				"/bin/sh", "-c", "exit 0",
			], { stdio: "ignore", timeout: 10_000 });
			if (test.status === 0) containmentBackend = "linux-pid-namespace";
		}
	}
	return containmentBackend;
}

/** Evidence mode for the stop gate, decided once per process. */
export function evidenceMode() {
	return evidenceModeFromProbe(probeContainment());
}

// ── Spawn ─────────────────────────────────────────────────────────────────────

function runScript(script, payload, timeoutMs, extraEnv, signal) {
	const child = spawn("bash", [script], {
		env: {
			...process.env,
			BOXLITE_HOOK_HOST: "omp",
			PLUGIN_ROOT: PLUGIN_ROOT,
			CLAUDE_PROJECT_DIR: process.env.CLAUDE_PROJECT_DIR ?? process.cwd(),
			...extraEnv,
		},
		stdio: ["pipe", "pipe", "pipe"],
	});
	let timedOut = false;
	const timer = setTimeout(() => {
		timedOut = true;
		child.kill("SIGTERM");
	}, timeoutMs);
	const onAbort = () => child.kill("SIGTERM");
	signal?.addEventListener("abort", onAbort, { once: true });
	child.stdin.on("error", () => {}); // a script that exits early must not crash the spawn
	child.stdin.end(JSON.stringify(payload));
	const stdout = [];
	const stderr = [];
	child.stdout.on("data", chunk => stdout.push(chunk));
	child.stderr.on("data", chunk => stderr.push(chunk));
	return new Promise(resolve => {
		child.on("close", code => {
			clearTimeout(timer);
			signal?.removeEventListener("abort", onAbort);
			resolve({
				code: code ?? -1,
				timedOut,
				stdout: Buffer.concat(stdout).toString("utf8"),
				stderr: Buffer.concat(stderr).toString("utf8"),
			});
		});
		child.on("error", () => {
			clearTimeout(timer);
			signal?.removeEventListener("abort", onAbort);
			resolve({ code: -1, timedOut: false, stdout: "", stderr: `${script} failed to start` });
		});
	});
}

const hookScript = script => join(HOOKS_DIR, script);

// ── Route execution ───────────────────────────────────────────────────────────

/** Run one PreToolUse route; block reasons follow Claude exit-code semantics. */
async function runPreToolUseRoute(route, payload, signal) {
	const result = await runScript(hookScript(route.script), payload, route.timeoutMs, {}, signal);
	if (result.timedOut) {
		return { block: true, reason: `${route.script} timed out after ${route.timeoutMs}ms` };
	}
	if (result.code === 2) {
		const reason = result.stderr.trim();
		return { block: true, reason: reason !== "" ? reason : `blocked by ${route.script}` };
	}
	return result.code === 0 ? null : { warnings: result.stderr.trim() };
}

/** Run the Stop gate and map its answer onto the OMP stop contract. */
export async function runStopGate(payload, signal) {
	const mode = evidenceMode();
	const extraEnv = mode === "transcript"
		? { VERDICT_EXTRACTOR_CMD: join(SCRIPTS_DIR, "omp-verdict-extractor.sh") }
		: {};
	const result = await runScript(hookScript("stop-gate.sh"), payload, STOP_TIMEOUT_MS, extraEnv, signal);
	return mapStopOutcome(result);
}

/** Map one stop-gate run onto the OMP stop result (exported for contract tests). */
export function mapStopOutcome(result) {
	if (result.timedOut) {
		return {
			decision: "block",
			reason: `boxlite-agent-tooling stop gate exceeded its ${STOP_TIMEOUT_MS}ms budget; resolve the verdict audit before settling`,
		};
	}
	const parsed = safeJsonObject(result.stdout);
	if (parsed?.decision === "block") {
		return { decision: "block", reason: parsed.reason || result.stderr.trim() || "blocked by the stop gate" };
	}
	if (result.code === 2) {
		return { decision: "block", reason: result.stderr.trim() || "blocked by the stop gate" };
	}
	return undefined;
}

function safeJsonObject(text) {
	try {
		const value = JSON.parse(text.trim());
		return value !== null && typeof value === "object" && !Array.isArray(value) ? value : null;
	} catch {
		return null;
	}
}

// ── Extension factory ─────────────────────────────────────────────────────────

export default function ompBridge(pi) {
	pi.on("before_agent_start", async (event, ctx) => {
		if (event.reason === "revive") return undefined;
		const payload = { ...basePayload(ctx, "UserPromptSubmit"), prompt: event.prompt ?? "" };
		const result = await runScript(hookScript("cancel-verdict-audit.sh"), payload, 30_000, {}, ctx?.signal);
		if (result.code !== 2) return undefined;
		// OMP cannot refuse a prompt here; surface the gate reply visibly instead.
		const reason = result.stderr.trim() || "blocked by cancel-verdict-audit.sh";
		return {
			message: {
				customType: "boxlite-agent-tooling",
				content: [{ type: "text", text: reason }],
				display: true,
				attribution: "agent",
			},
		};
	});

	pi.on("tool_call", async (event, ctx) => {
		const canon = canonicalToolName(event.toolName);
		if (canon === null) return undefined;
		const payload = preToolUsePayload(basePayload(ctx, "PreToolUse"), canon, event.input);
		const warnings = [];
		for (const route of routesForTool(canon)) {
			const outcome = await runPreToolUseRoute(route, payload, ctx?.signal);
			if (outcome === null) continue;
			if (outcome.block) return { block: true, reason: outcome.reason };
			if (outcome.warnings) warnings.push(outcome.warnings);
		}
		return warnings.length > 0 ? { additionalContext: warnings.join("\n\n") } : undefined;
	});

	pi.on("tool_result", async (event, ctx) => {
		if (event.toolName !== "bash") return undefined;
		const payload = {
			...basePayload(ctx, "PostToolUse"),
			tool_name: "Bash",
			tool_input: event.input ?? {},
			tool_response: toolResponseFrom(event),
		};
		await runScript(hookScript("post-remote-write-watch.sh"), payload, 15_000, {}, ctx?.signal);
		await runScript(hookScript("post-push-ledger-file.sh"), payload, 60_000, {}, ctx?.signal);
		// Claude routes failures through PostToolUseFailure; the script reads the
		// event name to tell the two apart.
		const recordPayload = { ...payload, hook_event_name: event.isError ? "PostToolUseFailure" : "PostToolUse" };
		await runScript(hookScript("record-test-run.sh"), recordPayload, 15_000, {}, ctx?.signal);
		return undefined;
	});

	pi.on("session_stop", async (event, ctx) => {
		if ((ctx?.agent?.kind ?? "main") !== "main") return undefined;
		const payload = stopPayload(basePayload(ctx, "Stop"), event, evidenceMode());
		return runStopGate(payload, ctx?.signal ?? event?.signal);
	});
}
