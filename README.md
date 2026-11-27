# claude-review-pack

A **silent second-opinion code review** for [Claude Code](https://claude.com/claude-code):
after Claude edits your code, an **independent reviewer** checks the change —
grounded in real linters, scoped to the diff, and gated by severity + confidence.
Two reviewers check every turn, tried in the order **claude → codex → grok → agy**
(Anthropic, OpenAI, xAI, Google): seat 1 is claude, seat 2 is codex, and grok,
then agy, fill a seat whose leg is not installed or fails. Each leg runs at most
once. Real findings from either seat block the turn and are fed back for Claude
to fix; everything else gets out of the way.

> The value is **model diversity across vendors**: a different model catches
> things Claude misses, and vice versa. The grounding + gating keep it from
> turning into noise. Two **verdicts** count per round, one per seat; when only
> one seat can be filled, the note says "only one reviewer ran".

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
3. **Fills two reviewer seats** — claude → codex → grok → agy: seat 1 claude,
   seat 2 codex, grok then agy into the first empty seat; each needs a
   schema-valid verdict (strict JSON via `schema.json`; the schema + reply rule
   are embedded in the prompt, and the codex leg also gets `--output-schema`).
   All legs share the reviewer instructions in `prompts/codex-review.md`.
   claude, grok and codex run read-only (claude `-p --model opus` with only the
   `Read,Grep,Glob` tools, no MCP servers and all hooks off, so it cannot start
   another review; grok via a `read_file,grep,list_dir` tool allowlist + `--deny`;
   codex via `-s read-only`); the agy leg has no read-only mode on the installed
   build, so it runs `--sandbox` (no shell) confined to the repo with
   `--add-dir` — it can still write **inside** that dir (see Known limitations).
   The whole review shares one time budget (`REVIEW_TIMEOUT`, default 540s)
   split across the installed legs, so a hung leg cannot eat the turn.
4. **Decides**: either seat blocks the turn if its finding is **major/blocker AND
   confidence ≥ floor**; `verdict.json` holds both seats' findings. Findings are injected back for Claude to fix, up to
   `REVIEW_MAX_ROUNDS`. Lower-severity/low-confidence findings are shown once,
   never looped.
5. **Later rounds are verify-only** — the reviewer checks whether prior findings
   were resolved instead of hunting for new ones (this kills the late-round
   false-positive escalation common to iterated LLM review).

## Fail-open by design

If **no** installed leg returns a schema-valid verdict — each one
unauthenticated, out of quota, timed out, erroring, or returning unparseable
output — the gate **releases the turn with a warning** that names why each leg
was skipped. It never traps you, and it never overwrites the previous
`verdict.json`. (LLM-CLI auth tokens expire mid-session; fail-open is
load-bearing, not a nicety.) Logs land in `.claude/.review-state/` (per-leg raw
output in `{claude,grok,agy,codex}.{out,err}`).

## Configuration (`.claude/review/config.sh`)

| Var | Default | Meaning |
|---|---|---|
| `REVIEW_MAX_ROUNDS` | `4` | Max reviewer↔author rounds before releasing |
| `REVIEW_BLOCK_SEVERITY` | `major` | Min severity that blocks the turn |
| `REVIEW_MIN_CONFIDENCE` | `4` | Min reviewer confidence (1–5) a finding needs to block |
| `REVIEW_CODEX_MODEL` | *(codex default)* | Override the codex-leg model only |
| `REVIEW_TIMEOUT` | `540` | Whole-review time budget (seconds), split across installed legs |
| `REVIEW_CODEX_TIMEOUT` | *(unset)* | Deprecated alias for `REVIEW_TIMEOUT`, still honoured |
| `REVIEW_MAX_FILE_LINES` | `900` | Per-file content cap sent to the reviewer |
| `REVIEW_GUARD` | `ask` | Bash guard: `ask` before destructive commands, or `off` to never ask (the review loop still runs). Set per machine, e.g. in the untracked `.claude/settings.local.json`: `{"env": {"REVIEW_GUARD": "off"}}` |
| `REVIEW_DISABLE` | `0` | Set `1` to disable the loop + bash guard entirely |

`REVIEW_TIMEOUT` is clamped to **30..540**; a non-numeric, out-of-range, or
over-long value falls back to **540**. The order **claude → codex → grok → agy**
is fixed and not configurable. Each leg's share is the time left divided by the
installed legs not yet tried, floored to that leg's own minimum when the budget
allows (15s for claude and codex, 25s for a catalogue leg such as grok or agy); a
leg whose share is below its minimum is skipped (`no time left`). Kill switch for
one session: `export REVIEW_DISABLE=1`.

## Install

1. Copy `.claude/` into your project root (next to your code).
2. Install the grounding tools:
   ```bash
   cd .claude/review/tools
   composer install   # PHPCS + WordPress Coding Standards
   npm install        # stylelint
   ```
   (ShellCheck / nginx / docker are used if present; optional.)
3. Authenticate at least one reviewer leg: `claude`, `codex`, `grok`, or `agy`
   (e.g. `codex login`); two give the full two-seat review. With none installed, the Stop hook exits silently.
4. Open `/hooks` in Claude Code once (or restart) so it picks up
   `.claude/settings.json`.

Requirements: `bash` (4.x or newer — the hook uses `mapfile` and `declare -A`),
`jq`, and at least one of the `claude` / `codex` / `grok` / `agy` CLIs; `php` for `php -l`
grounding. Grounding tools are optional and degrade gracefully.

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
  gate, not a full review of every command. It is fail-safe toward
  *allowing* (so it never jams routine work), which means a novel destructive
  pattern could slip it.
- **Two seats, not four votes.** At most two verdicts count per round
  (claude → codex → grok → agy fill two seats); the legs are not compared or
  voted, and either seat's blocking finding blocks the turn.
- **The claude leg uses your Claude login and quota.** It is a nested
  `claude -p` session: it reads your repository, spends your plan usage, and
  fails (so grok fills seat 1) when that login is out of usage.
- **Leg availability is not probed up front.** An installed-but-out-of-quota leg
  is discovered by trying it; its bounded share of `REVIEW_TIMEOUT` is spent
  before the next leg runs. Each leg's share is the time left divided by the legs
  not yet tried, floored to that leg's own minimum (15s for claude and codex, 25s
  for grok or agy) — but under a very tight budget a later fallback may still be
  skipped (`no time left`).
- **The agy (Antigravity) leg is not fully read-only.** claude, grok and codex are
  constrained to read-only tools; the installed agy build has no read-only mode,
  so its leg runs `--sandbox` (shell/terminal blocked) and `--add-dir`-confined
  to the repo, but a prompt-injection in reviewed content could still make it
  **write files inside the repo**. Reviewed edits are detectable via git. If you
  review untrusted content and cannot accept that, disable the loop
  (`REVIEW_DISABLE=1`) for that work, or remove `agy` from `PATH`.

## License

[Apache License 2.0](LICENSE) — Copyright 2026 Anton Dvornikov and contributors.
See [`NOTICE`](NOTICE).
