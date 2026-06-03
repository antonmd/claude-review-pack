# claude-review-pack

A **silent second-opinion code review** for [Claude Code](https://claude.com/claude-code):
after Claude edits your code, [Codex](https://openai.com/index/introducing-codex/)
reviews the change as an independent reviewer — grounded in real linters, scoped
to the diff, and gated by severity + confidence. Real findings block the turn
and are fed back for Claude to fix; everything else gets out of the way.

> The value is **model diversity**: a second model (GPT/Codex) catches things the
> first (Claude) misses, and vice versa. The grounding + gating keep it from
> turning into noise.

This is a WordPress / PHP / SCSS adaptation of the review-loop idea from the
[Prilive Go TDD Pack](https://github.com/prilive-com/go-tdd-pack) (same author);
the grounding layer is swappable, so the core works for any language.

---

## How it works

Three [Claude Code hooks](https://code.claude.com/docs/en/hooks-guide) wire the
loop, configured in `.claude/settings.json`:

| Hook | Script | What it does |
|---|---|---|
| **PostToolUse** (`Edit\|Write\|MultiEdit`) | `queue.sh` | Queues every edited reviewable file (`.php/.scss/.css/.js/.sh/.json/.yml/.conf/…`). |
| **Stop** | `stop-gate.sh` | When the turn ends: ground → review → decide. |
| **PreToolUse** (`Bash`) | `guard-bash.sh` | Asks for confirmation before destructive commands (`rm -rf`, `db drop`, `git push --force`, …). |

On **Stop**, the gate:

1. **Grounds** the queued files (`ground.sh`) with deterministic tools —
   `php -l`, PHPCS (security-focused WordPress ruleset), stylelint, ShellCheck,
   `jq`, `nginx -t`, `docker compose config`. Each tool degrades gracefully if
   absent.
2. **Builds a diff-scoped prompt**: for each file it sends the **diff since the
   last commit** (the lines to review) plus the **full file as read-only
   context** — so the reviewer understands the change without flagging
   pre-existing code.
3. **Calls Codex** (`codex exec`, read-only sandbox, strict JSON verdict via
   `schema.json`) with the reviewer instructions in `prompts/codex-review.md`.
4. **Decides**: a finding blocks the turn only if it is **major/blocker AND
   confidence ≥ floor**. Findings are injected back for Claude to fix, up to
   `REVIEW_MAX_ROUNDS`. Lower-severity/low-confidence findings are shown once,
   never looped.
5. **Later rounds are verify-only** — the reviewer checks whether prior findings
   were resolved instead of hunting for new ones (this kills the late-round
   false-positive escalation common to iterated LLM review).

## Fail-open by design

If Codex is unauthenticated, times out, errors, or returns unparseable output,
the gate **releases the turn with a warning** — it never traps you. (LLM-CLI
auth tokens expire mid-session; fail-open is load-bearing, not a nicety.) Logs
land in `.claude/.review-state/`.

## Configuration (`.claude/review/config.sh`)

| Var | Default | Meaning |
|---|---|---|
| `REVIEW_MAX_ROUNDS` | `4` | Max reviewer↔author rounds before releasing |
| `REVIEW_BLOCK_SEVERITY` | `major` | Min severity that blocks the turn |
| `REVIEW_MIN_CONFIDENCE` | `4` | Min Codex confidence (1–5) a finding needs to block |
| `REVIEW_CODEX_MODEL` | *(codex default)* | Override the Codex model |
| `REVIEW_CODEX_TIMEOUT` | `300` | Per-review timeout (seconds) |
| `REVIEW_MAX_FILE_LINES` | `900` | Per-file content cap sent to Codex |
| `REVIEW_DISABLE` | `0` | Set `1` to disable the loop + bash guard entirely |

Kill switch for one session: `export REVIEW_DISABLE=1`.

## Install

1. Copy `.claude/` into your project root (next to your code).
2. Install the grounding tools:
   ```bash
   cd .claude/review/tools
   composer install   # PHPCS + WordPress Coding Standards
   npm install        # stylelint
   ```
   (ShellCheck / nginx / docker are used if present; optional.)
3. Authenticate Codex: `codex login`.
4. Open `/hooks` in Claude Code once (or restart) so it picks up
   `.claude/settings.json`.

Requirements: `codex` CLI, `php`, `jq`, `bash`. Grounding tools are optional and
degrade gracefully.

## Design notes

- **Diff-scoped, not diff-only.** The reviewer gets the diff *and* full-file
  context — empirically, raw diff-only review lowers detection of contextual
  bugs; full-file-only causes it to flag unrelated pre-existing code. The hybrid
  reviews the change while understanding the file.
- **Grounding is the trust anchor.** When the LLM contradicts a clean
  deterministic tool result without a reproducible failure, that finding's
  confidence is capped — the linters are authoritative for the checks they
  perform.
- **Confidence routes, it doesn't suppress.** Every finding is shown; the
  confidence floor only decides what *blocks*. Nothing is hidden.

## Known limitations

- Reviews edits made through Claude's Edit/Write tools. Edits made another way
  (a container `docker cp`, an external editor) aren't queued.
- Diff scoping is *vs the last commit* — commit regularly to keep each review
  tight. Files outside any git repo fall back to full-file review.
- Command review (`guard-bash.sh`) is a local, pattern-matched **destructive-only**
  gate, not a full Codex review of every command. It is fail-safe toward
  *allowing* (so it never jams routine work), which means a novel destructive
  pattern could slip it.

## License

[Apache License 2.0](LICENSE) — Copyright 2026 Anton Dvornikov and contributors.
See [`NOTICE`](NOTICE).
