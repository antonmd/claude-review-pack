#!/usr/bin/env bash
# Tunables for the silent review loop. Sourced by the hooks.

# Max review rounds before giving up and letting the turn end (prevents
# infinite Claude<->reviewer loops). Each round is one second-opinion review
# (two seats: claude, codex; grok then agy fill an empty seat).
REVIEW_MAX_ROUNDS="${REVIEW_MAX_ROUNDS:-4}"

# Codex model. Empty (default) = omit --model entirely and let Codex CLI pick
# its own default. KEEP THIS EMPTY. Pinning a slug (gpt-5.x, *-codex, …) goes
# stale fast: upstream go-tdd-pack shipped three model-pin hotfixes in ten days
# before v2.3.2 reverted to "no pin, ever" (omit the flag, trust the CLI default).
# Set a slug only for a deliberate, temporary override — stop-gate.sh adds -m
# only when this is non-empty. (Only the codex leg reads this; claude uses the
# `opus` family alias, and grok and agy resolve their own newest model at run time.)
REVIEW_CODEX_MODEL="${REVIEW_CODEX_MODEL:-}"

# Hard time budget (seconds) for the WHOLE second-opinion review this turn. The
# review fills two seats from the installed reviewer legs in order — claude → codex → grok → agy — and
# the budget is split across the legs that are installed (so one hung leg is
# bounded to its share of the turn). stop-gate.sh clamps it to 30..540; anything
# else (non-numeric, out of range, >4 digits) falls back to the default 540.
#
# REVIEW_CODEX_TIMEOUT is the DEPRECATED name from the old codex-only loop. It is
# still honoured as the fallback when REVIEW_TIMEOUT is unset, so an existing
# override keeps working. Prefer REVIEW_TIMEOUT in new config.
REVIEW_CODEX_TIMEOUT="${REVIEW_CODEX_TIMEOUT:-}"
REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-${REVIEW_CODEX_TIMEOUT:-540}}"

# Minimum finding severity that actually BLOCKS the turn from ending.
# Findings below this are surfaced once but don't force another round.
# One of: blocker | major | minor | nit
REVIEW_BLOCK_SEVERITY="${REVIEW_BLOCK_SEVERITY:-major}"

# Minimum finding confidence (1-5) a finding needs to BLOCK the turn. Findings
# below this are still SHOWN, but don't force another round — this filters
# speculative overreach (routing, not suppression). Rounds are unchanged.
REVIEW_MIN_CONFIDENCE="${REVIEW_MIN_CONFIDENCE:-4}"

# Per-file content cap sent to the reviewer (lines). Keeps the prompt bounded.
REVIEW_MAX_FILE_LINES="${REVIEW_MAX_FILE_LINES:-900}"

# Bash guard (guard-bash.sh): "ask" (default) asks you before a command that
# looks destructive; "off" never asks (the review loop keeps running). Only the
# exact value "off" turns it off. Set it per machine, e.g. in the untracked
# .claude/settings.local.json: {"env": {"REVIEW_GUARD": "off"}}.
REVIEW_GUARD="${REVIEW_GUARD:-ask}"

# Kill switch: set to 1 to disable the whole loop (review + bash guard).
REVIEW_DISABLE="${REVIEW_DISABLE:-0}"
