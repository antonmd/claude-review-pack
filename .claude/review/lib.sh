#!/usr/bin/env bash
# Shared helpers for the silent review loop.

# Resolve key paths from this file's location (.claude/review/lib.sh).
REVIEW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$REVIEW_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CLAUDE_DIR/.." && pwd)"
STATE_DIR="$CLAUDE_DIR/.review-state"
TOOLS_DIR="$REVIEW_DIR/tools"

QUEUE_FILE="$STATE_DIR/queue"
ROUND_FILE="$STATE_DIR/round"
LOG_FILE="$STATE_DIR/review.log"

mkdir -p "$STATE_DIR" 2>/dev/null || true

review_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# Find the git repo root that contains $1 (a file path). Echoes the toplevel,
# or nothing if the file isn't inside a git work tree.
git_root_for() {
    local dir
    dir="$(dirname "$1")"
    git -C "$dir" rev-parse --show-toplevel 2>/dev/null
}

# Print the unified diff of $1 since the last commit (HEAD), within its repo.
# Includes staged + unstaged changes and brand-new untracked files. Echoes
# nothing if there's no git repo or no change (caller falls back to full file).
diff_for_file() {
    local f="$1" root
    root="$(git_root_for "$f")" || return 1
    [ -z "$root" ] && return 1
    local rel="${f#"$root"/}"

    # Tracked file with changes vs HEAD.
    if git -C "$root" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
        git -C "$root" diff --no-color --unified=3 HEAD -- "$rel" 2>/dev/null
    else
        # Untracked (new) file: diff against /dev/null so the whole file shows
        # as added — that IS the change.
        git -C "$root" diff --no-color --no-index --unified=3 /dev/null "$f" 2>/dev/null
    fi
}

# Is this path worth reviewing? Default-REVIEW: any text source file I edit is
# reviewed, EXCEPT dependencies, build output, generated/minified, lockfiles,
# binaries, and WP core. We exclude by what's NOT ours to review rather than
# allowlisting extensions — so a new config/script type is covered automatically.
reviewable_path() {
    local f="$1"
    # --- Never review: not ours, generated, or transient ---
    # Leading-anchored forms (node_modules/*) catch relative paths; */ forms
    # catch nested ones.
    case "$f" in
        node_modules/*|vendor/*|dist/*|build/*) return 1 ;;
        */node_modules/*|*/vendor/*|*/dist/*|*/build/*|*/.git/*) return 1 ;;
        *.min.js|*.min.css|*.min.*|*-lock.json|*.lock|*lock.json) return 1 ;;
        */wp-includes/*|*/wp-admin/*) return 1 ;;
        /tmp/*|*/.review-state/*|*/.review-test/*) return 1 ;;
    esac
    # --- Never review: binary / media / data blobs (no meaningful text review) ---
    case "$f" in
        *.png|*.jpg|*.jpeg|*.gif|*.webp|*.avif|*.ico|*.svg|*.woff|*.woff2|*.ttf|*.eot) return 1 ;;
        *.zip|*.tar|*.gz|*.tgz|*.pdf|*.mp4|*.mp3|*.mo) return 1 ;;
    esac
    # --- Review: known text source/config types we work in ---
    case "$f" in
        *.php|*.scss|*.css|*.js|*.mjs|*.cjs|*.ts) return 0 ;;     # code
        *.sh|*.bash) return 0 ;;                                  # shell
        *.json|*.yml|*.yaml|*.toml|*.ini|*.env) return 0 ;;       # config
        *.conf|*.nginx|*Dockerfile|Dockerfile*|*.dockerfile) return 0 ;; # infra
        *.html|*.htaccess|*.xml) return 0 ;;                      # markup/server
        *) return 1 ;;   # unknown (e.g. .md, .txt) — skip; no runtime risk
    esac
}

# Numeric rank for a severity so we can compare against REVIEW_BLOCK_SEVERITY.
severity_rank() {
    case "$1" in
        blocker) echo 4 ;;
        major)   echo 3 ;;
        minor)   echo 2 ;;
        nit)     echo 1 ;;
        *)       echo 0 ;;
    esac
}

# Read the current queue as a sorted, de-duplicated, existing-files-only list.
read_queue() {
    [ -f "$QUEUE_FILE" ] || return 0
    sort -u "$QUEUE_FILE" 2>/dev/null | while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$f" ] && printf '%s\n' "$f"
    done
}

reset_state() {
    rm -f "$QUEUE_FILE" "$ROUND_FILE" 2>/dev/null || true
}
