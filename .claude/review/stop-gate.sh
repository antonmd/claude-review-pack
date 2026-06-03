#!/usr/bin/env bash
# Stop hook: run a Codex second-opinion review on everything edited this turn.
# Blocks the turn from ending (feeding findings back to Claude) when there is a
# real issue; otherwise lets it end. Fails OPEN on any error.
set -uo pipefail

REVIEW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$REVIEW_DIR/config.sh"
# shellcheck source=/dev/null
source "$REVIEW_DIR/lib.sh"

# Emit a JSON object to Claude Code and exit. $1=json
emit() { printf '%s\n' "$1"; exit 0; }
# Surface a non-blocking note to the user, then allow stop.
note() { emit "$(jq -n --arg m "$1" '{systemMessage:$m}')"; }

[ "$REVIEW_DISABLE" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v codex >/dev/null 2>&1 || exit 0

# Drain stdin (stop hook payload); we key everything off our own round counter.
cat >/dev/null 2>&1 || true

mapfile -t FILES < <(read_queue)
[ "${#FILES[@]}" -eq 0 ] && exit 0   # nothing reviewable changed

round="$(cat "$ROUND_FILE" 2>/dev/null || echo 0)"
case "$round" in ''|*[!0-9]*) round=0 ;; esac

if [ "$round" -ge "$REVIEW_MAX_ROUNDS" ]; then
    review_log "max rounds ($REVIEW_MAX_ROUNDS) reached; releasing turn"
    reset_state
    note "⚠️ Codex review did not converge after $REVIEW_MAX_ROUNDS rounds — releasing. Review the remaining findings manually (see .claude/.review-state/review.log)."
fi

# --- Build the review prompt -------------------------------------------------
PROMPT="$STATE_DIR/prompt.txt"
OUT="$STATE_DIR/verdict.json"
CODEX_LOG="$STATE_DIR/codex.log"
: >"$PROMPT"

cat "$REVIEW_DIR/prompts/codex-review.md" >>"$PROMPT"
{
    echo; echo "---"; echo
    "$REVIEW_DIR/ground.sh" "${FILES[@]}"
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
    # verdict (it is truncated only just before the codex call below). This
    # removes the "find something new" pressure that drives late-round false
    # positives — without reducing the round count.
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
} >>"$PROMPT"

# --- Call Codex --------------------------------------------------------------
review_log "round $((round + 1)): reviewing ${#FILES[@]} file(s) via codex"
codex_args=(exec --skip-git-repo-check -s read-only -C "$REPO_ROOT"
            --output-schema "$REVIEW_DIR/schema.json"
            --output-last-message "$OUT" --color never)
[ -n "$REVIEW_CODEX_MODEL" ] && codex_args+=(-m "$REVIEW_CODEX_MODEL")

: >"$OUT"
timeout "$REVIEW_CODEX_TIMEOUT" codex "${codex_args[@]}" <"$PROMPT" >"$CODEX_LOG" 2>&1
rc=$?

if [ "$rc" -ne 0 ] && [ ! -s "$OUT" ]; then
    review_log "codex failed (rc=$rc); failing open"
    note "⚠️ Codex review could not run (exit $rc) — skipping this turn. See .claude/.review-state/codex.log."
fi

# Codex sometimes wraps the JSON in prose; extract the first {...} object.
verdict_json="$(jq -c . "$OUT" 2>/dev/null)"
if [ -z "$verdict_json" ]; then
    verdict_json="$(grep -ozP '(?s)\{.*\}' "$OUT" 2>/dev/null | tr -d '\0' | jq -c . 2>/dev/null || true)"
fi
if [ -z "$verdict_json" ]; then
    review_log "codex output unparseable; failing open"
    note "⚠️ Codex returned an unparseable review — skipping this turn. See .claude/.review-state/codex.log."
fi

verdict="$(printf '%s' "$verdict_json" | jq -r '.verdict // "approve"')"
block_rank="$(severity_rank "$REVIEW_BLOCK_SEVERITY")"
# Only findings at/above the confidence floor count toward the BLOCK decision.
# All findings are still shown in the feedback below (routing, not suppression).
max_rank="$(printf '%s' "$verdict_json" | jq -r --argjson minc "${REVIEW_MIN_CONFIDENCE:-1}" '
    [ .findings[]? | select( ( .confidence // 5 ) >= $minc ) | .severity ] | map(
        if . == "blocker" then 4 elif . == "major" then 3 elif . == "minor" then 2 elif . == "nit" then 1 else 0 end
    ) | max // 0')"

# --- Decide ------------------------------------------------------------------
if [ "$verdict" = "request_changes" ] && [ "${max_rank:-0}" -ge "$block_rank" ]; then
    round=$((round + 1))
    echo "$round" >"$ROUND_FILE"
    review_log "round $round: request_changes (max severity rank $max_rank) — blocking"

    reason="$(printf '%s' "$verdict_json" | jq -r '
        "🔍 Codex review (round '"$round"') requested changes:\n\n" + .summary + "\n\n" +
        ( [ .findings[]
            | "- **[\(.severity)]** `\(.file | sub(".*/";""))`" +
              (if .line then ":\(.line)" else "" end) +
              " — \(.message)" +
              (if .suggestion and .suggestion != "" then "\n  ↳ _\(.suggestion)_" else "" end)
          ] | join("\n") ) +
        "\n\nAddress the blocker/major items above, then finish. (Round '"$round"' of '"$REVIEW_MAX_ROUNDS"'.)"
    ')"
    emit "$(jq -n --arg r "$reason" '{decision:"block", reason:$r}')"
fi

# Approved (or only minor/nit findings) — release the turn.
review_log "verdict=$verdict max_rank=${max_rank:-0} — releasing"
reset_state
summary="$(printf '%s' "$verdict_json" | jq -r '.summary // "ok"')"
low="$(printf '%s' "$verdict_json" | jq -r '[.findings[]?] | length')"
if [ "${low:-0}" -gt 0 ]; then
    note "✅ Codex review passed (with ${low} minor note(s)): ${summary}"
fi
note "✅ Codex review passed: ${summary}"
