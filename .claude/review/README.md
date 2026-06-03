# Silent Codex review loop

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
   - Sends the changed files + linter output to **Codex** (`codex exec`,
     read-only sandbox, strict JSON verdict via `schema.json`), using the
     reviewer instructions in `prompts/codex-review.md` (your CLAUDE.md rules
     are baked in).
   - If Codex returns `request_changes` with a **major/blocker** finding, the
     turn is **blocked** and the findings are injected back into Claude's
     context to fix — up to `REVIEW_MAX_ROUNDS` times.
   - Otherwise the turn ends (minor/nit findings are surfaced once, not looped).

The review is a **second model** (Codex/GPT) checking Claude's work — the
diversity is the point: it catches things one model misses.

## Configuration — `config.sh`

| Var | Default | Meaning |
|---|---|---|
| `REVIEW_MAX_ROUNDS` | 4 | Max Claude↔Codex rounds before releasing |
| `REVIEW_CODEX_MODEL` | (codex default) | Override the Codex model |
| `REVIEW_CODEX_TIMEOUT` | 300 | Per-review timeout (s) |
| `REVIEW_BLOCK_SEVERITY` | major | Min severity that blocks the turn |
| `REVIEW_MAX_FILE_LINES` | 900 | Per-file content cap sent to Codex |
| `REVIEW_DISABLE` | 0 | Set `1` to disable the loop entirely |

Kill switch for one session: `export REVIEW_DISABLE=1`.

## Fail-open by design

If Codex is unauthenticated, times out, errors, or returns unparseable output,
the gate **releases the turn** with a warning — it never traps you. Logs:
`.claude/.review-state/{review,codex}.log`.

## Requirements

- `codex` CLI authenticated (`codex login`)
- `php`, `jq`
- Grounding tools installed under `tools/` (already done):
  `composer install` (PHPCS + WPCS) and `npm install` (stylelint).

## Known limitation

Only edits made through Claude's Edit/Write tools on **host paths** are
reviewed. All three themes (`techpulse`, `ciencia-al-dia`, `atlasfuturo`) live
under `wp/themes/` and are bind-mounted into the containers, so editing them is
reviewed. Edits written straight into a container via `docker cp`/`docker exec`
bypass the loop.
