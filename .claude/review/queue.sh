#!/usr/bin/env bash
# PostToolUse hook: enqueue reviewable files that were just edited.
# Always exits 0 — never interferes with the edit itself.
set -uo pipefail

REVIEW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$REVIEW_DIR/config.sh"
# shellcheck source=/dev/null
source "$REVIEW_DIR/lib.sh"

[ "$REVIEW_DISABLE" = "1" ] && exit 0

payload="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0

# Edit / Write / MultiEdit all carry tool_input.file_path.
fp="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -z "$fp" ] && exit 0

# Normalise to an absolute path.
case "$fp" in
    /*) abs="$fp" ;;
    *)  abs="$REPO_ROOT/$fp" ;;
esac

if reviewable_path "$abs"; then
    printf '%s\n' "$abs" >>"$QUEUE_FILE"
    review_log "queued: $abs"
fi

exit 0
