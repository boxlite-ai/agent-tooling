# Writing checks

## TL;DR

Stop and GitHub hooks share writing checks. The writing skill owns the prose rules.

See the [entry points](../ARCHITECTURE.md#entry-points) for the hooks that run these checks.

## GitHub writing

`.agents/lib/github-writing.sh` checks recognized `gh` PR/issue/discussion bodies, comments, reviews, close/reopen text, release notes, and REST body/description fields.

| Check | Contract |
| --- | --- |
| Structure | Every inspected body keeps the [structure limits](#structure-limits), TL;DR or not; one denial lists summary and structure fixes. |
| Summary | Inspected bodies need ≤39-word TL;DR; comments, reviews, and close/reopen text ≤80 words are exempt. |
| Counting | Unicode-aware; Chinese/Japanese characters count individually; table words contribute to totals. |
| Bounds | Empty text fails; no document word cap or shared character ceiling; snapshot/render limits remain separate. |
| Privacy | Scan titles and bodies of any length, including fences/comments; errors deny without echoing private text. |
| Privacy limits | Detect context/memory markup, explicit private attribution, home paths, and agent-context paths; no provenance or general secret guarantee. |

Only peer/higher headings end summaries; nested headings cannot reset them; denials reference `boxlite-writing` without consuming acknowledgment.

- Privacy also checks rendered author-review bot comments; no automatic disclosure exception exists.
- Credentials and permissions are unchanged; [workflow disclosure policy](../guidance/workflow.md#disclosure) covers facts, paraphrases, attachments, and unsupported publishing routes.
- Table-delimiter parsing stays linear, preserving Unicode whitespace, colons, escaped pipes, and matching cell counts; `.agents/lib/reply-summary.test.sh` covers correctness/performance.

### Shell inputs

The scanner supplies literal argv without execution, using per-command gh 2.92.0/pflag v1.0.10 specs in `_github_writing_spec`.

| Input | Decision |
| --- | --- |
| Literal inline text | Inspect before publication. |
| Body file, stdin, editor, generated text, GraphQL mutation | Reject because final text is unavailable. |
| Read-only / body-preserving command | Pass, including close/reopen without comments. |
| Unknown option, missing value, invalid boolean | Diagnostic naming option and `gh help`; no writing reminder. |
| Reached `-h` or final true `--help` | Pass literal argv, including PR create/edit/ready. |
| Portable plain output redirect | Remove from argv: optional fd 1/2, `>`, `>>`, `>|`, duplication/closing. |
| Input/ambiguous redirection or unsupported launcher | Remain nonliteral; visible writes fail closed. |

Escapes remain tracked (`\2>&1` stays argv); GraphQL detection skips strings/comments and recognizes ignored separators; new gh options require regenerated specs.

Other clients, script files, browser writes, and later bot edits remain outside this hook.

### Writing ownership

`scripts/sync-guidance.sh` generates workflow references, never skill copies; its revision/hash depends only on workflow text.

- Host discovery loads the skill; hooks/reminders do not read its body, so absence does not suppress the reference.
- `scripts/check-writing-ownership.sh` checks current guidance and tracked/untracked Markdown for copied eight-word passages or complete five-to-seven-word rules.
- Only verified root instruction blocks and fenced examples are exempt; diagnostics locate copies; paraphrases remain review work.
- [Writing CI](../../../.github/workflows/writing-ownership.yml) runs ownership, reference-delivery, TL;DR, and word-count tests on Linux; branch-rule enforcement is separate.
- Stop fixtures probe user/PID namespaces; CI permits `/usr/bin/unshare` through AppArmor.

## Mandatory summary

`.agents/lib/concise-writing.sh` validates the opening TL;DR for replies over 80 words; [writing skill](../.agents/skills/boxlite-writing/SKILL.md) owns prose rules.

| Check | Contract |
| --- | --- |
| Heading/content | ATX heading outside fences/quotes/comments; paragraph first, opening with word/emphasis/link/inline code. |
| Invalid first block | List, break, definition, setext heading, table. |
| Summary | Entire section ≤39 Unicode-counted words; denial states failure and literal fix/count. |
| Reminder | Append skill reference unless `no-hint`; GitHub caller supplies its own reminder. |
| Stop continuation | Check only when `stop_hook_active` is false; one correction maximum, then continue other gates. |
| Missing/empty text | Missing uses bounded transcript; unreadable/truncated denies even on continuation; explicit empty never replays prior text. |

Internal instructions/tool payloads need no summary; Stop does not shorten prose or judge form choice and cannot retract streamed commentary.

## Structure limits

`.agents/lib/reply-summary.pl` measures the [writing skill](../.agents/skills/boxlite-writing/SKILL.md) limits; `.agents/lib/reply-summary.sh` owns the numbers, and its test ties them to the skill text; `.agents/lib/concise-writing.sh` words the correction ([#419](https://github.com/boxlite-ai/agent-tooling/issues/419)).

| Check | Contract |
| --- | --- |
| Limits | ≤3 sentences per prose block or list item; ≤25 words per sentence; lists of 2–7 items, sub-lists of 2–3, at most 3 levels; tables of 2–5 columns. |
| Splitting | Perl 5.22+ `\b{sb}` (UAX #29) after masking code spans, URLs, link targets, and abbreviations; a forced break before `#`, a digit, or inline code after terminal punctuation. |
| Skipped | Fences, HTML comments, headings, table cells, blockquotes; the TL;DR and Chinese/Japanese sentences skip the word limit. |
| Scope | Stop replies of any length and every inspected GitHub body; design registration checks only the summary. |
| Correction | One message lists up to five violations and counts the rest; Stop names the skill once; a checker failure fails closed, and Stop exits 2. |
| Bounds | Whitespace and long punctuation runs collapse before splitting, so parsing stays linear. |

GitHub CLI and fetched design content keep independent mandatory checks; shared guidance applies across unsupported surfaces too.
