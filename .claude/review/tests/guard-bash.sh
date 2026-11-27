#!/usr/bin/env bash
# Tests guard-bash.sh (the PreToolUse:Bash gate): it asks before a destructive
# command by default, and never asks when REVIEW_GUARD=off. Each row runs the
# guard from a temp copy of .claude/review under `env -i`. rc 1 on any FAIL.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .claude/review/tests
SRC="$(cd "$HERE/.." && pwd)"                          # .claude/review
PASS=0; FAIL=0

TMP="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/review"
cp "$SRC/guard-bash.sh" "$SRC/config.sh" "$SRC/lib.sh" "$TMP/.claude/review/" \
    || { echo "FATAL: copy failed" >&2; exit 2; }

DESTRUCTIVE='rm -rf /tmp/some-dir'
HARMLESS='ls -la'

# run_guard <command> [VAR=val ...] -> sets OUT and RC
run_guard() {
    local cmd="$1"; shift
    OUT="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' \
        | env -i HOME="$TMP" PATH="/usr/bin:/bin" "$@" bash "$TMP/.claude/review/guard-bash.sh" 2>/dev/null)"
    RC=$?
}
# An "ask" must exit 0 (Claude Code reads exit 2 as a BLOCK, not as a question)
# and name its event: Claude Code requires hookEventName "PreToolUse".
asks() {
    [ "$RC" = 0 ] && [ "$(printf '%s' "$OUT" | jq -r '(.hookSpecificOutput.hookEventName // "") + "/" +
        (.hookSpecificOutput.permissionDecision // "")' 2>/dev/null)" = PreToolUse/ask ]
}
silent() { [ "$RC" = 0 ] && [ -z "$OUT" ]; }
LOG="$TMP/.claude/.review-state/review.log"
asklines() { local n; n="$(grep -c 'guard-bash: ASK' "$LOG" 2>/dev/null)"; echo "${n:-0}"; }
row() {   # row <name> <detail> <cond 0|1>
    if [ "$3" = 1 ]; then printf 'PASS %s %s\n' "$1" "$2"; PASS=$((PASS + 1))
    else printf 'FAIL %s %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); fi
}
ok() { if "$@"; then echo 1; else echo 0; fi; }

OTHER='truncate -s 0 /tmp/some-file'   # a second destructive rule, not rm

run_guard "$DESTRUCTIVE"
row G-DEFAULT "destructive command, default -> ask" "$(ok asks)"

run_guard "$HARMLESS"
row G-SAFE "harmless command, default -> no output" "$(ok silent)"

run_guard "$DESTRUCTIVE" REVIEW_GUARD=off
row G-OFF "REVIEW_GUARD=off + destructive -> no output, rc 0" "$(ok silent)"

run_guard "$HARMLESS" REVIEW_GUARD=off
row G-OFF-SAFE "REVIEW_GUARD=off + harmless -> no output" "$(ok silent)"

run_guard "$OTHER" REVIEW_GUARD=off
row G-OFF-OTHER "REVIEW_GUARD=off + truncate (not rm) -> no output" "$(ok silent)"

before="$(asklines)"; run_guard "$DESTRUCTIVE" REVIEW_GUARD=off; after="$(asklines)"
row G-OFF-NOLOG "REVIEW_GUARD=off writes no 'guard-bash: ASK' log line ($before -> $after)" \
    "$(ok test "$before" = "$after")"

run_guard "$DESTRUCTIVE" REVIEW_GUARD=bogus
row G-BOGUS "REVIEW_GUARD=bogus -> still asks (unknown value = default)" "$(ok asks)"

run_guard "$DESTRUCTIVE" REVIEW_GUARD=OFF
row G-CASE "REVIEW_GUARD=OFF (upper case) -> still asks (only 'off' turns it off)" "$(ok asks)"

exact=1
for v in Off 'off ' ' off' office of no; do
    run_guard "$DESTRUCTIVE" REVIEW_GUARD="$v"; asks || { exact=0; echo "  value [$v] did not ask"; }
done
row G-EXACT "near-miss values (Off, 'off ', ' off', office, of, no) -> still ask" "$exact"

run_guard "$DESTRUCTIVE" REVIEW_DISABLE=1
row G-DISABLE "REVIEW_DISABLE=1 -> no output (the old all-off switch still works)" "$(ok silent)"

printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
