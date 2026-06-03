#!/usr/bin/env bash
# Tunables for the silent review loop. Sourced by the hooks.

# Max review rounds before giving up and letting the turn end (prevents
# infinite Claude<->Codex loops). Each round is one Codex review.
REVIEW_MAX_ROUNDS="${REVIEW_MAX_ROUNDS:-4}"

# Codex model. Empty = whatever `codex` is configured to use by default.
REVIEW_CODEX_MODEL="${REVIEW_CODEX_MODEL:-}"

# Hard timeout (seconds) for a single Codex review call. On timeout we fail open.
REVIEW_CODEX_TIMEOUT="${REVIEW_CODEX_TIMEOUT:-300}"

# Minimum finding severity that actually BLOCKS the turn from ending.
# Findings below this are surfaced once but don't force another round.
# One of: blocker | major | minor | nit
REVIEW_BLOCK_SEVERITY="${REVIEW_BLOCK_SEVERITY:-major}"

# Minimum Codex confidence (1-5) a finding needs to BLOCK the turn. Findings
# below this are still SHOWN, but don't force another round — this filters
# speculative overreach (routing, not suppression). Rounds are unchanged.
REVIEW_MIN_CONFIDENCE="${REVIEW_MIN_CONFIDENCE:-4}"

# Per-file content cap sent to Codex (lines). Keeps the prompt bounded.
REVIEW_MAX_FILE_LINES="${REVIEW_MAX_FILE_LINES:-900}"

# Kill switch: set to 1 to disable the whole loop (review + bash guard).
REVIEW_DISABLE="${REVIEW_DISABLE:-0}"
