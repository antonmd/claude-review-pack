#!/usr/bin/env bash
# PreToolUse:Bash gate — stops the turn to ask the operator before a
# DESTRUCTIVE / irreversible command runs. This is a HUMAN gate, not a Codex
# gate: it returns permissionDecision "ask" so YOU approve the dangerous op.
#
# Design choices (deliberate):
# - Scope = destructive/irreversible ONLY. Routine reversible mutations
#   (docker compose up, npm install, git commit, mkdir, cp) are NOT gated —
#   gating everything would make the workflow unusable and push toward disable.
# - Pattern-matched locally (no Codex call) → zero latency, works offline.
# - FAIL-SAFE toward NOT trapping: on any internal error or unparseable input
#   we ALLOW (exit 0). A safety prompt that jams normal work gets disabled;
#   one that occasionally misses a pattern is recoverable. We optimise for the
#   gate staying ON. The genuinely irreversible patterns below are the ones
#   that matter, and they are matched conservatively.
# - Kill switch: REVIEW_DISABLE=1 (shared with the review loop).
set -uo pipefail

REVIEW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$REVIEW_DIR/config.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$REVIEW_DIR/lib.sh" 2>/dev/null || true

# Allow the command (let the normal permission flow proceed).
allow() { exit 0; }
# Ask the operator first, with a reason.
ask() {
    jq -n --arg r "$1" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}' \
        2>/dev/null || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
    exit 0
}

[ "${REVIEW_DISABLE:-0}" = "1" ] && allow
command -v jq >/dev/null 2>&1 || allow   # no jq → can't parse → fail-safe allow

payload="$(cat 2>/dev/null)" || allow
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)" || allow
[ -z "$cmd" ] && allow

# Normalise to a single line for matching (commands can be multi-line).
scan="$(printf '%s' "$cmd" | tr '\n' ' ')"

# Strip benign discard redirects (>/dev/null, 2>/dev/null, &>/dev/null, etc.)
# BEFORE the overwrite rule runs — writing to /dev/null is not a file clobber,
# and these appear in almost every real command (including this gate's own
# scripts). Without this, the absolute-path redirect rule false-positives.
scan_fs="$(printf '%s' "$scan" | sed -E 's#[0-9]*&?>>?[[:space:]]*/dev/(null|stdout|stderr)##g')"

# --- Destructive / irreversible patterns (extended regex) -------------------
# Each entry: "regex|human reason". Conservative — aimed at irreversible ops.
matched_reason=""
# $1 = regex, $2 = reason, $3 = haystack (defaults to $scan; $scan_fs for the
# redirect rule so /dev/null discards are already stripped out).
match() { printf '%s' "${3:-$scan}" | grep -Eq "$1" && matched_reason="$2"; }

# Filesystem destruction
match 'rm[[:space:]]+(-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]|-[a-zA-Z]*[rf][a-zA-Z]*$)' \
      'Recursive/forced file deletion (rm -r/-f) — irreversible.'
match '(^|[[:space:];&|])(truncate|shred)[[:space:]]' \
      'truncate/shred — destroys file contents irreversibly.'
# Single > (not >>) overwriting an absolute path, scanned AFTER /dev/null is
# stripped. `[^>]` avoids matching >> (append) and the second char of >>.
match '(^|[^>])>[[:space:]]*/[a-zA-Z]' \
      'Redirect (>) overwriting an absolute path — clobbers file contents.' \
      "$scan_fs"
match 'chmod[[:space:]]+-[a-zA-Z]*R|chown[[:space:]]+-[a-zA-Z]*R' \
      'Recursive permission/ownership change — wide blast radius.'

# Git history / remote rewriting
match 'git[[:space:]]+push[[:space:]].*(--force|-f([[:space:]]|$))' \
      'git push --force — can overwrite remote history.'
match 'git[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]+-[a-zA-Z]*[fd]|checkout[[:space:]]+--[[:space:]]|restore[[:space:]])' \
      'git hard reset / clean — discards uncommitted work.'
match 'git[[:space:]]+branch[[:space:]]+-D' \
      'git branch -D — force-deletes a branch.'

# Database / WordPress destructive ops
match 'wp[[:space:]]+db[[:space:]]+(drop|reset|clean)' \
      'wp db drop/reset — destroys the WordPress database.'
match 'wp[[:space:]]+(post|user|term|option|site)[[:space:]]+delete' \
      'wp ... delete — removes WordPress content/config.'
match 'wp[[:space:]]+search-replace' \
      'wp search-replace — mass-rewrites DB rows across tables.'
match '(DROP|TRUNCATE|DELETE[[:space:]]+FROM)[[:space:]]' \
      'Raw SQL DROP/TRUNCATE/DELETE — irreversible data loss.'
match 'mysql[[:space:]].*(-e|<)' \
      'Direct mysql execution — can change/destroy DB state.'

# Container / volume destruction
match 'docker[[:space:]]+compose[[:space:]]+down[[:space:]].*(-v|--volumes)' \
      'docker compose down -v — deletes named volumes (data loss).'
match 'docker[[:space:]]+(volume[[:space:]]+rm|system[[:space:]]+prune|rmi)' \
      'docker volume rm / system prune — removes volumes/images.'

# Package / system level
match '(^|[[:space:];&|])(mkfs|dd)[[:space:]]' \
      'mkfs/dd — can destroy a filesystem/disk.'
match 'apt(-get)?[[:space:]]+(remove|purge|autoremove)|snap[[:space:]]+remove' \
      'System package removal — affects the host.'

if [ -n "$matched_reason" ]; then
    review_log "guard-bash: ASK on destructive cmd: $scan" 2>/dev/null || true
    ask "⚠️ Potentially destructive command — approve before running.

Command:
  $cmd

Reason flagged: $matched_reason

This is a local safety gate (pattern-matched, not Codex). Approve if intended."
fi

allow
