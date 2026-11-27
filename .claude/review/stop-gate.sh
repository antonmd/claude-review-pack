#!/usr/bin/env bash
# Stop hook: run a second-opinion review on everything edited this turn.
# Two reviewer seats, order claude → codex → grok → agy: seat 1 claude, seat 2
# codex; grok, then agy, fill the first seat that is still empty. Each leg runs
# at most once; it stops when both seats hold a schema-valid verdict. Blocks the turn (feeding findings back to Claude) on a real issue;
# otherwise lets it end. Fails OPEN on any error.
set -uo pipefail

REVIEW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$REVIEW_DIR/config.sh"
# shellcheck source=/dev/null
source "$REVIEW_DIR/lib.sh"

# Emit a JSON object to Claude Code and exit. $1=json
emit() { printf '%s\n' "$1"; exit 0; }
# Surface a non-blocking note to the user, then allow stop.
note() { emit "$(printf '%s' "$1" | jq -Rs '{systemMessage:.}')"; }

[ "$REVIEW_DISABLE" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# --- Reviewer legs: two seats, order claude → codex → grok → agy ------------
# Count the DISTINCT installed ones. If NONE is installed, review nothing (exit
# silently). An uninstalled leg is simply never attempted.
n_installed=0
for leg in claude codex grok agy; do
    command -v "$leg" >/dev/null 2>&1 && n_installed=$((n_installed + 1))
done
[ "$n_installed" -eq 0 ] && exit 0   # no reviewer available at all

# Drain stdin (stop hook payload); we key everything off our own round counter.
cat >/dev/null 2>&1 || true

mapfile -t FILES < <(read_queue)
[ "${#FILES[@]}" -eq 0 ] && exit 0   # nothing reviewable changed

round="$(cat "$ROUND_FILE" 2>/dev/null || echo 0)"
case "$round" in ''|*[!0-9]*) round=0 ;; esac

if [ "$round" -ge "$REVIEW_MAX_ROUNDS" ]; then
    review_log "max rounds ($REVIEW_MAX_ROUNDS) reached; releasing turn"
    reset_state
    note "⚠️ Second-opinion review did not converge after $REVIEW_MAX_ROUNDS rounds — releasing. Review the remaining findings manually (see .claude/.review-state/review.log)."
fi

OUT="$STATE_DIR/verdict.json"       # the last VALID verdict only (never truncated)
PROMPT="$STATE_DIR/prompt.txt"

# --- One-time state clear: drop stale per-leg raw outputs (NOT verdict.json) -
if ! rm -f "$STATE_DIR"/claude.out "$STATE_DIR"/claude.err \
            "$STATE_DIR"/grok.out "$STATE_DIR"/grok.err \
            "$STATE_DIR"/agy.out  "$STATE_DIR"/agy.err \
            "$STATE_DIR"/codex.out "$STATE_DIR"/codex.err 2>/dev/null; then
    review_log "cannot clear review state; failing open"
    note "⚠️ Second-opinion review cannot clear review state — skipping this turn."
fi
# Raw leg output stays PRIVATE until the turn ends: it is written outside the repo,
# and each finished leg's files are locked (mode 000, see attempt()), so a later
# seat cannot read an earlier seat's answer while it reviews. When the hook exits,
# the files are unlocked and move into the review-state folder (for debugging),
# and the private folder is removed.
# The base is made absolute BEFORE mktemp (leg_claude changes to the repo root before
# it writes into the folder), so LEG_DIR is mktemp's own absolute path or empty, and
# never "$PWD/" — the EXIT trap below removes LEG_DIR.
leg_base="${TMPDIR:-/tmp}"
case "$leg_base" in /*) ;; *) leg_base="$PWD/$leg_base" ;; esac
if ! LEG_DIR="$(mktemp -d "$leg_base/review-legs.XXXXXX" 2>/dev/null)" || [ ! -d "$LEG_DIR" ]; then
    review_log "cannot create the private leg folder; failing open"
    note "⚠️ Second-opinion review cannot create its private work folder — skipping this turn."
fi
trap 'chmod 600 "$LEG_DIR"/* 2>/dev/null; mv -f "$LEG_DIR"/* "$STATE_DIR"/ 2>/dev/null; rm -rf "$LEG_DIR"' EXIT

# --- Resolve the time budget (seconds), guarded ------------------------------
# Accept only 1–4 ASCII digits in 30..540; anything else → 540. The explicit
# [0123456789] class (not [0-9]) rejects non-ASCII digits under UTF-8 locales.
T="$REVIEW_TIMEOUT"
case "$T" in
    ''|*[!0123456789]*) T=540 ;;
    *)
        if [ "${#T}" -ge 1 ] && [ "${#T}" -le 4 ]; then
            T=$((10#$T))
            { [ "$T" -ge 30 ] && [ "$T" -le 540 ]; } || T=540
        else
            T=540
        fi
        ;;
esac
START=$SECONDS
GDEADLINE=$((START + T))

# --- Build the review prompt -------------------------------------------------
: >"$PROMPT"
cat "$REVIEW_DIR/prompts/codex-review.md" >>"$PROMPT"
{
    echo; echo "---"; echo
    gsecs=$((T / 3)); [ "$gsecs" -lt 1 ] && gsecs=1
    if ! timeout -k 5 "$gsecs" "$REVIEW_DIR/ground.sh" "${FILES[@]}"; then
        echo; echo "(grounding timed out)"
    fi
    echo "---"; echo
    echo "## Changed files (${#FILES[@]})"
    echo
    echo "For each file you get: (1) the DIFF since the last commit — these are"
    echo "the lines THIS change added/modified, and the ONLY lines you should"
    echo "raise findings on; and (2) the full file as read-only CONTEXT, so you"
    echo "can understand the change. Do NOT raise findings on CONTEXT lines the"
    echo "diff did not touch, unless a pre-existing line is *directly broken by*"
    echo "this change. If a file shows no diff, the whole file is the context and"
    echo "you may review it normally."
    for f in "${FILES[@]}"; do
        rel="${f#"$REPO_ROOT"/}"
        ext="${f##*.}"
        diff_out="$(diff_for_file "$f" 2>/dev/null)"
        echo
        echo "### $rel"
        if [ -n "$diff_out" ]; then
            echo
            echo "#### === CHANGED (review these lines) ==="
            echo '```diff'
            printf '%s\n' "$diff_out" | sed -n "1,${REVIEW_MAX_FILE_LINES}p"
            echo '```'
            echo
            echo "#### === CONTEXT (full file, do not flag unchanged lines) ==="
        else
            echo
            echo "_(no diff available — reviewing full file)_"
        fi
        echo '```'"$ext"
        sed -n "1,${REVIEW_MAX_FILE_LINES}p" "$f"
        nlines="$(wc -l <"$f" 2>/dev/null || echo 0)"
        [ "${nlines:-0}" -gt "$REVIEW_MAX_FILE_LINES" ] && echo "/* … truncated at $REVIEW_MAX_FILE_LINES lines … */"
        echo '```'
    done

    # Round N>1 is VERIFY-ONLY: at this point $OUT still holds the prior round's
    # verdict. This removes the "find something new" pressure that drives late-
    # round false positives — without reducing the round count.
    if [ "$round" -ge 1 ] && [ -s "$OUT" ]; then
        echo; echo "---"; echo
        echo "## Review round $((round + 1)) — VERIFY ONLY"
        echo "The author has revised the code in response to the prior findings below."
        echo "Your job this round is to verify, not to hunt:"
        echo "- For each prior finding, judge whether the revision resolved it."
        echo "- Open a NEW finding ONLY if it is severity blocker/major, grounded or"
        echo "  reproducible, AND newly introduced by the latest change."
        echo "- Do NOT raise fresh style/nitpick findings. If the prior issues are"
        echo "  resolved, return verdict \"approve\"."
        echo
        echo "Prior findings:"
        echo '```json'
        jq -c '[.findings[]? | {file, line, severity, message}]' "$OUT" 2>/dev/null || echo "[]"
        echo '```'
    fi

    # The legs have no --output-schema flag (only codex does), so the schema and
    # the reply rule are embedded here. The reply rule is the LAST line.
    echo; echo "---"; echo
    echo "## Output schema"
    echo '```json'
    cat "$REVIEW_DIR/schema.json"
    echo '```'
    echo
    echo "Reply with exactly one JSON object that matches this schema."
} >>"$PROMPT"

# --- Parser: port of proto/p14.sh. parse_one echoes the normalized valid -----
# verdict JSON, or nothing. Text before the first "{" is not read.
strict_one() {   # $1=text → 0 VALID (echoes JSON), 1 parsed-but-invalid, 2 not-JSON
    local t="$1" n
    n="$(printf '%s' "$t" | jq -s length 2>/dev/null)" || return 2
    [ "$n" = 1 ] || return 1
    [ "$(printf '%s' "$t" | jq -c -n --stream '[inputs]' 2>/dev/null)" = "$(printf '%s' "$t" | jq -c '[tostream]' 2>/dev/null)" ] || return 1
    printf '%s' "$t" | jq -ce "$VALID_VERDICT"' select(valid_verdict)' 2>/dev/null || return 1
}
parse_one() {    # $1=raw answer text → echoes normalized valid verdict JSON, or nothing
    local t="$1" v rc
    v="$(strict_one "$t")"; rc=$?
    if [ "$rc" -ne 2 ]; then
        [ "$rc" -eq 0 ] && printf '%s' "$v"
        return
    fi
    t="${t%$'\r'}"
    [[ "$t" == *$'\n```' ]] && t="${t%$'\n```'}"
    [[ "$t" == *'{'* ]] || return
    v="$(strict_one "{${t#*'{'}")"; rc=$?
    [ "$rc" -eq 0 ] && printf '%s' "$v"
}

# --- The four reviewer legs --------------------------------------------------
# Each sets LEG_TEXT (raw answer text) and returns 0 on a clean GATE pass, or
# sets LEG_REASON and returns 1. They write raw stdout/stderr to per-leg files.
LEG_TEXT=""; LEG_REASON=""

# Collapse all whitespace runs to one space and cut to 160 chars.
collapse_cut() { local s; s="$(jq -Rrs 'gsub("\\s+";" ")' 2>/dev/null)"; printf '%s' "${s:0:160}"; }

leg_cat_limit() {   # echo min(leg_deadline-SECONDS, 10, share/3), floor 1
    local avail=$((LEG_DEADLINE - SECONDS))
    local third=$((SHARE / 3))
    local lim="$avail"
    [ "$lim" -gt 10 ] && lim=10
    [ "$lim" -gt "$third" ] && lim="$third"
    [ "$lim" -lt 1 ] && lim=1
    echo "$lim"
}

leg_grok() {
    local clim def secs stop text keys rc
    clim="$(leg_cat_limit)"
    def="$(REVIEW_DISABLE=1 timeout -k 5 "$clim" grok models 2>/dev/null | sed -n 's/^Default model: //p' | head -1)"
    if [ -z "$def" ]; then LEG_REASON="no default model"; return 1; fi
    secs=$((LEG_DEADLINE - SECONDS - 5))
    if [ "$secs" -lt 10 ]; then LEG_REASON="no time left"; return 1; fi
    REVIEW_DISABLE=1 GROK_CLAUDE_AGENTS_ENABLED=0 GROK_CLAUDE_SKILLS_ENABLED=0 \
        GROK_CLAUDE_MCPS_ENABLED=0 GROK_CLAUDE_HOOKS_ENABLED=0 \
        timeout -k 5 "$secs" grok --prompt-file "$PROMPT" --effort high --always-approve \
            --output-format json --no-subagents --tools read_file,grep,list_dir \
            --disallowed-tools CallMcpTool --deny 'mcp__*' --cwd "$REPO_ROOT" \
            >"$LEG_DIR/grok.out" 2>"$LEG_DIR/grok.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        local msg; msg="$(jq -r '.message // empty' "$LEG_DIR/grok.out" 2>/dev/null | collapse_cut)"
        LEG_REASON="exit $rc"; [ -n "$msg" ] && LEG_REASON="exit $rc: $msg"
        return 1
    fi
    if ! jq -e . "$LEG_DIR/grok.out" >/dev/null 2>&1; then LEG_REASON="not JSON"; return 1; fi
    stop="$(jq -r '.stopReason // empty' "$LEG_DIR/grok.out" 2>/dev/null)"
    [ "$stop" = end_turn ] || { LEG_REASON="stopReason ${stop:-none}"; return 1; }
    text="$(jq -r '.text // empty' "$LEG_DIR/grok.out" 2>/dev/null)"
    [ -n "$text" ] || { LEG_REASON="empty text"; return 1; }
    keys="$(jq -r '.modelUsage // {} | keys | join(",")' "$LEG_DIR/grok.out" 2>/dev/null)"
    case "$keys" in
        *,*) LEG_REASON="served '$keys', default '$def'"; return 1 ;;
        "$def"*) : ;;
        *) LEG_REASON="served '$keys', default '$def'"; return 1 ;;
    esac
    LEG_TEXT="$text"; return 0
}

leg_agy() {
    local clim cat M secs status served resp rc
    clim="$(leg_cat_limit)"
    cat="$(REVIEW_DISABLE=1 timeout -k 5 "$clim" agy --output-format json models </dev/null 2>/dev/null)"
    M="$(printf '%s' "$cat" | jq -r '
        [ .command.data.models[]?.id // empty
          | select(test("^gemini-[0-9.]+-[a-z]+-medium$"))
          | {id: ., v: (capture("^gemini-(?<v>[0-9.]+)-") | .v | split(".") | map(tonumber))} ]
        | if length == 0 then empty else (max_by(.v) | .id) end' 2>/dev/null)"
    if [ -z "$M" ]; then LEG_REASON="no gemini medium model"; return 1; fi
    secs=$((LEG_DEADLINE - SECONDS - 5))
    if [ "$secs" -lt 10 ]; then LEG_REASON="no time left"; return 1; fi
    # stdin is ONE NDJSON message per line (agy stream-json), so -c is required:
    # a pretty-printed object spans several lines and agy rejects the bare "{".
    # agy has no read-only mode on this build (--dangerously-skip-permissions is
    # the only way it uses tools at all), so we add --sandbox to block the shell
    # and confine it to the repo with --add-dir; it can still WRITE inside that
    # dir — see the README's security limitation.
    jq -cRs '{event:"user",message:{role:"user",content:.}}' <"$PROMPT" 2>/dev/null \
        | REVIEW_DISABLE=1 timeout -k 5 "$secs" agy --model "$M" --dangerously-skip-permissions \
            --sandbox --print-timeout "${secs}s" --disable-slash-commands --add-dir "$REPO_ROOT" \
            --input-format stream-json --output-format stream-json \
            >"$LEG_DIR/agy.out" 2>"$LEG_DIR/agy.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        local e; e="$(jq -r 'select(.event=="result")|.result.error // empty' "$LEG_DIR/agy.out" 2>/dev/null | collapse_cut)"
        LEG_REASON="exit $rc"; [ -n "$e" ] && LEG_REASON="exit $rc: $e"
        return 1
    fi
    status="$(jq -r 'select(.event=="result")|.result.status // empty' "$LEG_DIR/agy.out" 2>/dev/null)"
    [ "$status" = SUCCESS ] || { LEG_REASON="status not SUCCESS"; return 1; }
    served="$(jq -r 'select(.event=="init")|.init.model // empty' "$LEG_DIR/agy.out" 2>/dev/null)"
    [ "$served" = "$M" ] || { LEG_REASON="served model is not $M"; return 1; }
    resp="$(jq -r 'select(.event=="result")|.result.response // empty' "$LEG_DIR/agy.out" 2>/dev/null)"
    [ -n "$resp" ] || { LEG_REASON="empty response"; return 1; }
    LEG_TEXT="$resp"; return 0
}

leg_codex() {
    local secs rc args
    # No catalogue step: the run limit is the share minus the 5 s kill grace. attempt()
    # gives claude/codex a share of at least 15 s, so secs is at least 10.
    secs=$((SHARE - 5))
    args=(exec --skip-git-repo-check -s read-only -C "$REPO_ROOT"
          --output-schema "$REVIEW_DIR/schema.json"
          --output-last-message "$LEG_DIR/codex.out" --color never)
    [ -n "$REVIEW_CODEX_MODEL" ] && args+=(-m "$REVIEW_CODEX_MODEL")
    REVIEW_DISABLE=1 timeout -k 5 "$secs" codex "${args[@]}" \
        <"$PROMPT" >"$LEG_DIR/codex.log" 2>"$LEG_DIR/codex.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        local e; e="$(head -1 "$LEG_DIR/codex.err" 2>/dev/null | cut -c1-160)"
        LEG_REASON="exit $rc"; [ -n "$e" ] && LEG_REASON="exit $rc: $e"
        return 1
    fi
    [ -s "$LEG_DIR/codex.out" ] || { LEG_REASON="no answer file"; return 1; }
    LEG_TEXT="$(cat "$LEG_DIR/codex.out")"
    return 0
}

leg_claude() {
    local secs rc e t served
    secs=$((SHARE - 5))   # as leg_codex: no catalogue step, share >= 15 s
    # Recursion guard: the nested session runs with disableAllHooks (hooks from managed
    # settings can still run), and REVIEW_DISABLE=1 makes THIS hook exit at once.
    # Read-only: Read/Grep/Glob only, no MCP servers, no saved session.
    ( cd "$REPO_ROOT" && REVIEW_DISABLE=1 timeout -k 5 "$secs" claude -p --model opus \
        --output-format json --tools Read,Grep,Glob --permission-mode dontAsk \
        --no-session-persistence --strict-mcp-config --settings '{"disableAllHooks":true}' \
        <"$PROMPT" >"$LEG_DIR/claude.out" 2>"$LEG_DIR/claude.err" )
    rc=$?
    if [ "$rc" -ne 0 ]; then
        e="$(head -1 "$LEG_DIR/claude.err" 2>/dev/null | collapse_cut)"
        LEG_REASON="exit $rc"; [ -n "$e" ] && LEG_REASON="exit $rc: $e"
        return 1
    fi
    if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$LEG_DIR/claude.out" >/dev/null 2>&1; then
        LEG_REASON="not JSON"; return 1
    fi
    # Typed: is_error must be the boolean false and .result a string.
    t="$(jq -r 'if .type == "result" and .subtype == "success" and .is_error == false
                   and (.result | type) == "string" then "ok"
                else "\(.type)/\(.subtype)/\(.is_error)/\(.result | type)" end' "$LEG_DIR/claude.out" 2>/dev/null)"
    [ "$t" = ok ] || { LEG_REASON="result $t"; return 1; }
    # Every model that served must be Claude, and one of them Opus.
    served="$(jq -r '.modelUsage // {} | keys | join(",")' "$LEG_DIR/claude.out" 2>/dev/null)"
    if ! jq -e '(.modelUsage // {} | keys) as $k
            | all($k[]; startswith("claude-")) and any($k[]; startswith("claude-opus-"))' \
            "$LEG_DIR/claude.out" >/dev/null 2>&1; then
        LEG_REASON="served '$served'"; return 1
    fi
    LEG_TEXT="$(jq -r '.result // empty' "$LEG_DIR/claude.out" 2>/dev/null)"
    [ -n "$LEG_TEXT" ] || { LEG_REASON="empty result"; return 1; }
    return 0
}

# --- Two seats, like the main flow: seat 1 claude, seat 2 codex --------------
# Attempt order claude → codex → grok → agy; each installed leg at most ONCE.
# claude and codex try their own seat; grok, then agy, fill the FIRST still-empty
# seat. Stop as soon as both seats hold a valid verdict.
# Budget: a leg's share is wall/untried (untried = installed legs not yet tried,
# this one included), floored to the leg's minimum while the wall still holds it:
#   * claude/codex need 15s (5s kill-grace + 10s review; no catalogue step),
#   * grok/agy need 25s (5s grace + up to 10s model-catalogue lookup + 10s review).
# A share below the leg's minimum is SKIPPED ("no time left"); the leg still counts
# as tried, so it holds no time for later legs.
reasons=()
SEAT_LEG=("" ""); SEAT_V=("" "")
untried=$n_installed
# SHARE stays GLOBAL: leg_cat_limit reads it for the catalogue limit.
# Lock every raw file in the private folder (mode 000). The later legs' tools are
# read-only (claude Read/Grep/Glob, grok read_file/grep/list_dir, agy --sandbox,
# codex -s read-only), so they cannot change a mode back. File modes do not bind
# root.
lock_leg_files() {
    local f
    for f in "$LEG_DIR"/*; do
        [ -e "$f" ] || continue
        chmod 000 "$f" 2>/dev/null || return 1
    done
    return 0
}
attempt() {   # attempt <leg> <seat 0|1> → on a valid verdict fills SEAT_LEG/SEAT_V
    local leg="$1" seat="$2" m=25 wall v div lrc
    case "$leg" in claude|codex) m=15 ;; esac
    wall=$((GDEADLINE - SECONDS))
    div=$untried; [ "$div" -lt 1 ] && div=1
    SHARE=$((wall / div))
    [ "$SHARE" -lt "$m" ] && [ "$wall" -ge "$m" ] && SHARE="$m"
    [ "$SHARE" -gt "$wall" ] && SHARE="$wall"
    untried=$((untried - 1))
    if [ "$SHARE" -lt "$m" ]; then
        reasons+=("$leg: no time left"); review_log "$leg: no time left"; return 0
    fi
    LEG_DEADLINE=$((SECONDS + SHARE)); LEG_TEXT=""; LEG_REASON=""
    review_log "round $((round + 1)): reviewing ${#FILES[@]} file(s) via $leg (share ${SHARE}s)"
    "leg_$leg"; lrc=$?
    # Lock this leg's answer before any later leg starts.
    if ! lock_leg_files; then
        review_log "cannot lock $leg's raw files; failing open"
        note "⚠️ Second-opinion review cannot lock a reviewer's raw files — skipping this turn."
    fi
    if [ "$lrc" -eq 0 ]; then
        v="$(parse_one "$LEG_TEXT")"
        if [ -n "$v" ]; then SEAT_LEG[seat]="$leg"; SEAT_V[seat]="$v"; return 0; fi
        reasons+=("$leg: invalid verdict"); review_log "$leg: invalid verdict"
    else
        reasons+=("$leg: $LEG_REASON"); review_log "$leg: $LEG_REASON"
    fi
    return 0
}
command -v claude >/dev/null 2>&1 && attempt claude 0
command -v codex  >/dev/null 2>&1 && attempt codex 1
for leg in grok agy; do
    command -v "$leg" >/dev/null 2>&1 || continue
    if   [ -z "${SEAT_LEG[0]}" ]; then attempt "$leg" 0
    elif [ -z "${SEAT_LEG[1]}" ]; then attempt "$leg" 1
    fi
done

# Reasons of the legs that did not give a verdict (for the note).
skipped=""
if [ "${#reasons[@]}" -gt 0 ]; then
    j="$(printf '%s; ' "${reasons[@]}")"; skipped=" (${j%; })"
fi
filled=()   # seat numbers that hold a verdict, in seat order
for s in 0 1; do [ -n "${SEAT_LEG[s]}" ] && filled+=("$s"); done
legs="$(for s in "${filled[@]}"; do printf '%s+' "${SEAT_LEG[s]}"; done)"; legs="${legs%+}"

# --- No seat holds a verdict: fail OPEN, leave verdict.json untouched --------
if [ "${#filled[@]}" -eq 0 ]; then
    review_log "no reviewer returned a valid verdict; failing open"
    note "⚠️ No reviewer could run${skipped} — skipping this turn. See .claude/.review-state/review.log."
fi

# --- Decide ------------------------------------------------------------------
# One combined verdict for the next round's verify-only prompt: request_changes if
# any seat says so, "<leg>: <summary>" per seat, and every seat's findings.
VALID_VERDICT_JSON="$(for s in "${filled[@]}"; do
        printf '%s' "${SEAT_V[s]}" | jq -c --arg l "${SEAT_LEG[s]}" '. + {leg: $l}'
    done | jq -cs '{
        verdict: (if any(.[]; .verdict == "request_changes") then "request_changes" else "approve" end),
        summary: (map(.leg + ": " + (.summary // "ok")) | join(" | ")),
        findings: (map(.findings // []) | add // [])
    }' 2>/dev/null)"
verdict="$(printf '%s' "$VALID_VERDICT_JSON" | jq -r '.verdict // "approve"')"
block_rank="$(severity_rank "$REVIEW_BLOCK_SEVERITY")"
# A seat blocks when it says request_changes with a finding at/above the block
# severity and the confidence floor. Either seat can block.
seat_rank() {
    printf '%s' "$1" | jq -r --argjson minc "${REVIEW_MIN_CONFIDENCE:-1}" '
        [ .findings[]? | select( ( .confidence // 5 ) >= $minc ) | .severity ] | map(
            if . == "blocker" then 4 elif . == "major" then 3 elif . == "minor" then 2 elif . == "nit" then 1 else 0 end
        ) | max // 0'
}
blocking=()
for s in "${filled[@]}"; do
    sv="$(printf '%s' "${SEAT_V[s]}" | jq -r '.verdict // "approve"')"
    sr="$(seat_rank "${SEAT_V[s]}")"
    [ "$sv" = request_changes ] && [ "${sr:-0}" -ge "$block_rank" ] && blocking+=("$s")
done

# Build the whole block decision FIRST, every part checked: if any part cannot be
# built, fail open before verdict.json or the round changes.
decfail() {
    review_log "cannot build the block decision; failing open"
    note "⚠️ Second-opinion review could not build its decision — skipping this turn."
}
dec=""
if [ "${#blocking[@]}" -gt 0 ]; then
    round=$((round + 1))
    reason=""
    for s in "${blocking[@]}"; do
        sec="$(printf '%s' "${SEAT_V[s]}" | jq -r --arg leg "${SEAT_LEG[s]}" --arg rd "$round" '
            "🔍 \($leg) review (round \($rd)) requested changes:\n\n" + .summary + "\n\n" +
            ( [ .findings[]
                | "- **[\(.severity)]** `\(.file | sub(".*/";""))`" +
                  (if .line then ":\(.line)" else "" end) +
                  " — \(.message)" +
                  (if .suggestion and .suggestion != "" then "\n  ↳ _\(.suggestion)_" else "" end)
              ] | join("\n") )')" || sec=""
        [ -n "$sec" ] || decfail
        reason="${reason:+$reason$'\n\n'}$sec"
    done
    reason="$reason"$'\n\n'"Address the blocker/major items above, then finish. (Round $round of $REVIEW_MAX_ROUNDS.)"
    # By stdin: two seats' findings can pass one argument's 128 KiB limit.
    dec="$(printf '%s' "$reason" | jq -Rs '{decision:"block", reason:.}' 2>/dev/null)" || dec=""
    [ -n "$dec" ] || decfail
fi
# Save it atomically (temp + rename) so verdict.json is never torn. If the save
# FAILS, fail OPEN right here — do NOT advance the round or block the turn, or the
# next round's verify-only prompt would read a stale/absent verdict.
if [ -n "$VALID_VERDICT_JSON" ] && printf '%s' "$VALID_VERDICT_JSON" | jq -c . >"$OUT.tmp" 2>/dev/null \
        && mv -f "$OUT.tmp" "$OUT" 2>/dev/null && [ -f "$OUT" ]; then
    :
else
    rm -f "$OUT.tmp" 2>/dev/null
    review_log "cannot save verdict.json; failing open"
    note "⚠️ Second-opinion review could not save its verdict — skipping this turn."
fi
if [ "${#blocking[@]}" -gt 0 ]; then
    echo "$round" >"$ROUND_FILE"
    review_log "round $round: request_changes via $legs — blocking"
    emit "$dec"
fi

# Approved (or only minor/nit findings) — release the turn.
review_log "verdict=$verdict via $legs — releasing"
reset_state
parts=()
for s in "${filled[@]}"; do
    sm="$(printf '%s' "${SEAT_V[s]}" | jq -r '.summary // "ok"')"
    nlow="$(printf '%s' "${SEAT_V[s]}" | jq -r '[.findings[]?] | length')"
    part="✅ ${SEAT_LEG[s]} review passed"
    [ "${nlow:-0}" -gt 0 ] && part="$part (with ${nlow} minor note(s))"
    parts+=("$part: $sm")
done
msg="$(printf '%s | ' "${parts[@]}")"; msg="${msg% | }"
[ "${#filled[@]}" -eq 1 ] && msg="$msg | ⚠️ only one reviewer ran"
note "$msg$skipped"
