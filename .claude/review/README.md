# Silent second-opinion review loop

An automated second-opinion code review for this project, inspired by
[prilive-com/go-tdd-pack](https://github.com/prilive-com/go-tdd-pack) but
rebuilt for a **WordPress / PHP / SCSS** codebase (the original is Go-only).

## How it works

1. **PostToolUse hook** (`queue.sh`) — every time Claude edits a `.php`,
   `.scss`, `.css`, or `.js` file, its path is added to a queue.
   (`.claude/settings.json` wires this on `Edit|Write|MultiEdit`.)
2. **Stop hook** (`stop-gate.sh`) — when Claude finishes a turn:
   - Runs grounding linters on the queued files (`ground.sh`):
     `php -l`, **PHPCS** with a security-focused WordPress ruleset
     (`phpcs.xml`), and **stylelint** for SCSS/CSS.
   - Sends the changed files + linter output to **two independent reviewers**,
     trying the installed reviewer CLIs in order **claude → codex → grok → agy**:
     seat 1 is claude, seat 2 is codex, and grok then agy fill the first empty
     seat; each leg runs at most once and needs a schema-valid verdict
     (`schema.json`). The reviewer instructions in `prompts/codex-review.md`
     (your CLAUDE.md rules baked in) are shared by every leg; the schema and a
     one-line reply rule are appended to the prompt (only the codex leg also
     gets `--output-schema`).
   - If either seat returns `request_changes` with a finding at or above `REVIEW_BLOCK_SEVERITY` (default **major**: major/blocker) at confidence ≥ `REVIEW_MIN_CONFIDENCE`,
     the turn is **blocked** and the findings are injected back into
     Claude's context to fix — up to `REVIEW_MAX_ROUNDS` times.
   - Otherwise the turn ends (minor/nit findings are surfaced once, not looped).

The value is **model diversity across vendors** (Anthropic, OpenAI, xAI, Google):
a different model checking Claude's work catches things one model misses. Two
verdicts count per round, one per seat; `verdict.json` holds both seats'
findings, and the note says "only one reviewer ran" when one seat stays empty.

## Configuration — `config.sh`

| Var | Default | Meaning |
|---|---|---|
| `REVIEW_MAX_ROUNDS` | 4 | Max review↔fix rounds before releasing |
| `REVIEW_CODEX_MODEL` | (codex default) | Override the codex-leg model only |
| `REVIEW_TIMEOUT` | 540 | Whole-review time budget (s), split across the installed legs |
| `REVIEW_CODEX_TIMEOUT` | (unset) | Deprecated alias for `REVIEW_TIMEOUT`, still honoured |
| `REVIEW_BLOCK_SEVERITY` | major | Min severity that blocks the turn |
| `REVIEW_MIN_CONFIDENCE` | 4 | Min finding confidence (1–5) that blocks |
| `REVIEW_MAX_FILE_LINES` | 900 | Per-file content cap sent to the reviewer |
| `REVIEW_GUARD` | ask | Bash guard: `ask` before destructive commands, or `off` to never ask (the loop still runs); e.g. `{"env": {"REVIEW_GUARD": "off"}}` in the untracked `.claude/settings.local.json` |
| `REVIEW_DISABLE` | 0 | Set `1` to disable the loop entirely |

`REVIEW_TIMEOUT` is clamped to **30..540**; a non-numeric, out-of-range, or
over-long value falls back to **540**. The budget is divided across the legs
that are actually installed, so one hung leg is bounded to its share, and grounding
runs under its own `timeout` (one third of the budget). Each distinct installed
leg's share is the time left divided by the installed legs not yet tried,
floored to that leg's own minimum when the budget allows (15s claude and codex,
25s catalogue leg); a share below the minimum is skipped (`no time left`). The
order claude → codex → grok → agy is fixed and not configurable.

Kill switch for one session: `export REVIEW_DISABLE=1`.

## Fail-open by design

If **no** installed leg returns a schema-valid verdict — each one unauthenticated,
out of quota, timed out, erroring, or returning an unparseable/ill-shaped answer —
the gate **releases the turn** with a warning that names why each leg was skipped.
It never traps you, and it never overwrites the previous `verdict.json`. Logs:
`.claude/.review-state/review.log` and the per-leg raw outputs
`.claude/.review-state/{claude,grok,agy,codex}.{out,err}`. While the turn runs, each
leg writes those files into a private folder outside the repo (under `$TMPDIR`), and
each finished leg's files are locked (mode 000) before the next leg starts, so a later
seat, whose tools are read-only, cannot read an earlier seat's answer. The lock relies
on file modes, so it does not hold when the hook runs as root. The files are unlocked
and move into `.claude/.review-state/` when the hook ends.

## Requirements

- `bash` 4.x or newer (the hook uses `mapfile` and `declare -A`).
- At least one of the reviewer CLIs authenticated: `claude`, `codex`, `grok`, or `agy`
  (with no leg installed at all, the hook exits silently and reviews nothing).
- `jq`; `php` for `php -l` grounding.
- Grounding tools installed under `tools/` (already done):
  `composer install` (PHPCS + WPCS) and `npm install` (stylelint).

## Known limitations (stated, not hidden)

- **Host paths only.** Only edits made through Claude's Edit/Write tools on
  **host paths** are reviewed. All three themes (`techpulse`, `ciencia-al-dia`,
  `atlasfuturo`) live under `wp/themes/` and are bind-mounted into the
  containers, so editing them is reviewed. Edits written straight into a
  container via `docker cp`/`docker exec` bypass the loop.
- **Two seats, not four votes.** At most two verdicts count per round; the
  legs are not compared or voted, and either seat's blocking finding blocks.
- **The claude leg uses your Claude login and quota** (a nested `claude -p
  --model opus` session with only `Read,Grep,Glob`, no MCP servers and
  `disableAllHooks`; hooks from managed settings can still run there, and
  `REVIEW_DISABLE=1` stops this hook in it). When that login is out of usage it
  fails: then grok, then agy, fills seat 1; if neither can, seat 1 stays empty and
  the note says only one reviewer ran; if seat 2 is empty too, the note says no reviewer could run.
- **Leg availability is not probed up front.** A leg that is installed but out
  of quota is discovered by trying it (its budget share is spent before the next
  leg runs); the budget split bounds that cost.
- **The budget is a bounded per-leg share.** Each leg's share is the time left
  divided by the installed legs not yet tried, floored to that leg's own minimum
  when the budget allows (15s for claude and codex, 25s for a catalogue leg such
  as grok or agy, so a tight budget still runs it). Under a very tight budget a
  later fallback may still be skipped (`no time left`) rather than failing the turn.
- **The agy leg is not fully read-only.** claude (`Read,Grep,Glob` only), grok
  (tool allowlist + `--deny`) and codex (`-s read-only`) are read-only; the installed agy build has no read-only
  mode, so its leg runs `--sandbox` (no shell) and `--add-dir`-confined to the
  repo, yet a prompt-injection in reviewed content could still make it write
  files inside the repo. Reviewing untrusted content and can't accept that?
  Disable the loop (`REVIEW_DISABLE=1`) or remove `agy` from `PATH`.
