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
asks() { [ "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = ask ]; }
row() {   # row <name> <detail> <cond 0|1>
    if [ "$3" = 1 ]; then printf 'PASS %s %s\n' "$1" "$2"; PASS=$((PASS + 1))
    else printf 'FAIL %s %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); fi
}
ok() { if "$@"; then echo 1; else echo 0; fi; }

run_guard "$DESTRUCTIVE"
row G-DEFAULT "destructive command, default -> ask" "$(ok asks)"

run_guard "$HARMLESS"
row G-SAFE "harmless command, default -> no output" "$(ok test "$RC" = 0 -a -z "$OUT")"

run_guard "$DESTRUCTIVE" REVIEW_GUARD=off
row G-OFF "REVIEW_GUARD=off + destructive -> no output, rc 0" "$(ok test "$RC" = 0 -a -z "$OUT")"

run_guard "$HARMLESS" REVIEW_GUARD=off
row G-OFF-SAFE "REVIEW_GUARD=off + harmless -> no output" "$(ok test "$RC" = 0 -a -z "$OUT")"

run_guard "$DESTRUCTIVE" REVIEW_GUARD=bogus
row G-BOGUS "REVIEW_GUARD=bogus -> still asks (unknown value = default)" "$(ok asks)"

run_guard "$DESTRUCTIVE" REVIEW_GUARD=OFF
row G-CASE "REVIEW_GUARD=OFF (upper case) -> still asks (only 'off' turns it off)" "$(ok asks)"

run_guard "$DESTRUCTIVE" REVIEW_DISABLE=1
row G-DISABLE "REVIEW_DISABLE=1 -> no output (the old all-off switch still works)" "$(ok test "$RC" = 0 -a -z "$OUT")"

printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
