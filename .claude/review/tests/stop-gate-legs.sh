#!/usr/bin/env bash
# Tests the two-seat review in stop-gate.sh (PLAN-twoseat, dsf): seat 1 claude,
# seat 2 codex, grok then agy fill an empty seat. Each row builds its own throwaway project under mktemp,
# installs stub CLIs, runs the hook under `env -i`, and checks the hook JSON, the
# call log, the state files and the wall time. Self rows run first. rc 1 on any FAIL.
#
# An optional argument is a regex selecting which rows to run (e.g. 'L-PARSE').
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .claude/review/tests
REVIEW_SRC="$(cd "$HERE/.." && pwd)"                   # .claude/review
SEL="${1:-}"

# PREFLIGHT HARD GATE: the hook runs with PATH=$T/bin:/usr/bin:/bin, so a real
# reviewer installed in /usr/bin:/bin would run whenever a row removes its stub,
# silently invalidating every absence/fallback row (and SELF-3 could reach it too).
# Refuse to run at all in such an environment — abort BEFORE any stub build, SELF
# row, or reviewer call. SELF-7 below records the same fact for the report.
for _rl in claude grok agy codex; do
    if PATH="/usr/bin:/bin" command -v "$_rl" >/dev/null 2>&1; then
        echo "FATAL: real reviewer '$_rl' on the system PATH (/usr/bin:/bin); refusing to run — tests would hit it instead of the stubs" >&2
        exit 3
    fi
done

PASS=0; FAIL=0; SELF_FAIL=0; T_FAIL=0; SEL_HITS=0

# One temp root for every fixture, removed by the EXIT trap (cleanup_all), so no
# row — even a SELF row that forgets its own rm — leaves a directory behind.
HARNESS_TMP="$(mktemp -d)" || { echo "FATAL: mktemp -d failed for HARNESS_TMP" >&2; exit 2; }

# rep <self 0|1> <row> <detail> <cond 0|1>
rep() {
    local self="$1" row="$2" det="$3" cond="$4"
    if [ "$cond" = 1 ]; then
        printf 'PASS %s %s\n' "$row" "$det"; PASS=$((PASS + 1))
    else
        printf 'FAIL %s %s\n' "$row" "$det"; FAIL=$((FAIL + 1))
        if [ "$self" = 1 ]; then SELF_FAIL=$((SELF_FAIL + 1)); else T_FAIL=$((T_FAIL + 1)); fi
    fi
}
# bool <cmd...> -> echoes 1 if the command succeeds, else 0
bool() { if "$@"; then echo 1; else echo 0; fi; }
# has <haystack> <needle> -> 1 if needle is a substring
has() { case "$1" in *"$2"*) echo 1 ;; *) echo 0 ;; esac; }
# run a row only when it matches the selector
sel() {
    [ -z "$SEL" ] && return 0
    [[ "$1" =~ $SEL ]] || return 1
    SEL_HITS=$((SEL_HITS + 1)); return 0
}

# ---------------------------------------------------------------------------
# The 70 frozen parser inputs (proto/cases14), rebuilt here as EXACT bytes by a
# python helper from embedded `repr()` literals -- no shell/heredoc decodes the
# literal `\u` escapes or the non-ASCII bytes (TESTPLAN rev 7). Built once.
# ---------------------------------------------------------------------------
CASES_DIR="$(mktemp -d -p "$HARNESS_TMP")" || { echo "FATAL: mktemp -d failed for CASES_DIR" >&2; exit 2; }
[ -n "$CASES_DIR" ] && [ -d "$CASES_DIR" ] || { echo "FATAL: empty/invalid CASES_DIR" >&2; exit 2; }
build_cases() {
    python3 -I - "$CASES_DIR" <<'PYEOF'
import sys, os
d = sys.argv[1]
CASES = {
    'align_two': b'\xd0\x9f\xd1\x80\xd0\xbe\xd0\xb2\xd0\xb5\xd1\x80\xd0\xba\xd0\xb0 \xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f\xd1\x8f{ {"verdict":"request_changes","summary":"issue","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"fix it","suggestion":null}]}\n{"verdict":"approve","summary":"ok","findings":[]}',
    'arr': b'[{"verdict":"approve","summary":"ok","findings":[]}]',
    'big': b'x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} x {y} {"verdict":"approve","summary":"ok","findings":[]} Done.',
    'blank_fence': b'I reviewed a.php.\n\n```json\n{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}\n```',
    'braces_first': b'I checked {} {"verdict":"request_changes","summary":"issue","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"fix it","suggestion":null}]}',
    'colon_ok': b'Here is the JSON:\n{"verdict":"request_changes","summary":"issue","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"fix it","suggestion":null}]}',
    'dup_container': b'{"verdict":{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]},"verdict":"approve","summary":"ok","findings":[]}',
    'dup_esc': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}],"ver\\u0064ict":"approve"}',
    'dup_findings': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}],"findings":[]}',
    'dup_lit': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}],"verdict":"approve"}',
    'dup_nl': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}],"verdict"\n:"approve"}',
    'dup_sev': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","severity":"nit","confidence":5,"message":"A real bug","suggestion":null}]}',
    'esc_two': b'Review: {"summary":"s","ver\\u0064ict":"request_changes","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}\n{"verdict":"approve","summary":"ok","findings":[]}',
    'f1bad': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"high","confidence":5,"message":"A real bug","suggestion":null},{"file":"a.php","line":2,"severity":"minor","confidence":5,"message":"A small issue","suggestion":null}]}',
    'f2bad': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"minor","confidence":5,"message":"A small issue","suggestion":null},{"file":"a.php","line":2,"severity":"high","confidence":5,"message":"A real bug","suggestion":null}]}',
    'f_extra': b'{"verdict":"approve","summary":"ok","findings":[{"file":"a","line":1,"severity":"nit","confidence":2,"message":"m","suggestion":null,"extra":1}]}\n',
    'fence_crlf': b'```json\r\n{"verdict":"request_changes","summary":"issue","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"fix it","suggestion":null}]}\r\n```\r\n',
    'fence_crlf_open': b'Here:\r\n```json\r\n{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}\r\n```\r\n',
    'jslit': b'{findings: [{file: a.php, line: 1, severity: blocker, message: SQL injection}]}\n{"verdict":"approve","summary":"ok","findings":[]}',
    'lim_brace': b'I will check foo() { first.{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}',
    'lim_braces': b'I will check foo() { first. {"verdict":"request_changes","summary":"x } y { z","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"fix it","suggestion":null}]}',
    'lim_critical': b'Critical: XSS in a.php:3, must fix. {"verdict":"approve","summary":"ok","findings":[]}',
    'lim_path': b'Reading {path} now. {"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}',
    'lim_rcprose': b'Result: request_changes (a.php:3 XSS). {"verdict":"approve","summary":"ok","findings":[]}',
    'lim_trail': b'{"verdict":"approve","summary":"ok","findings":[]}\nDone.',
    'lim_uni': b'Pr\xc3\xbcfe caf\xc3\xa9 {x} jetzt. {"verdict":"approve","summary":"\xc3\xb1 ok","findings":[]}',
    'lim_verdictword': b'I will read a.php and then give my verdict. {"verdict":"request_changes","summary":"s","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"m","suggestion":null}]}',
    'lim_word': b'Here is my verdict: {"verdict":"approve","summary":"ok","findings":[]}',
    'majority': b'I checked the majority of a.php. {"verdict":"approve","summary":"ok","findings":[]}',
    'md_ff': b'Findings:\n- a.php:1 blocker - SQL injection\n\n{"verdict":"approve","summary":"ok","findings":[]}',
    'measured': b'I\'ll start by reading the brief...{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}',
    'miss': b'{"verdict":"request_changes","summary":"s","findings":[{"file":"a","severity":"blocker","confidence":5,"message":"m"}]}',
    'ml_draft': b'Problems:\n- a.php line 1: SQL injection (critical)\n\n{"verdict":"approve","summary":"ok","findings":[]}',
    'narr_dup': b'I\'ll start by reading the brief...{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}],"verdict":"approve"}',
    'narr_f1bad': b'I\'ll start by reading the brief...{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"high","confidence":5,"message":"A real bug","suggestion":null},{"file":"a.php","line":2,"severity":"minor","confidence":5,"message":"A small issue","suggestion":null}]}',
    'narr_f2bad': b'I\'ll start by reading the brief...{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"minor","confidence":5,"message":"A small issue","suggestion":null},{"file":"a.php","line":2,"severity":"high","confidence":5,"message":"A real bug","suggestion":null}]}',
    'narr_fextra': b'I\'ll start by reading the brief...{"verdict":"approve","summary":"ok","findings":[{"file":"a","line":1,"severity":"nit","confidence":2,"message":"m","suggestion":null,"extra":1}]}',
    'narr_miss': b'I\'ll start by reading the brief...{"verdict":"request_changes","summary":"s","findings":[{"file":"a.php","severity":"blocker","confidence":5,"message":"m"}]}',
    'narr_nested': b'I\'ll start by reading the brief...{"verdict":"approve","summary":"ok","findings":[],"previous":{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}}',
    'narr_two': b'Review:\n{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}\n{"verdict":"approve","summary":"ok","findings":[]}',
    'nested_extra': b'{"verdict":"approve","summary":"ok","findings":[],"previous":{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}}',
    'nobrace': b'"verdict":"approve","summary":"ok","findings":[]}',
    'num_ap': b'42\n{"verdict":"approve","summary":"ok","findings":[]}',
    'ok_ap': b'{"verdict":"approve","summary":"ok","findings":[]}',
    'ok_apos': b'I\'ll check a.php. {"verdict":"approve","summary":"ok","findings":[]}',
    'ok_crlf': b'{"verdict"\r\n:"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}',
    'ok_esckey': b'{"ver\\u0064ict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}',
    'ok_escq': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"m \\"verdict\\": x","suggestion":null}]}',
    'ok_fence': b'Here:\n```json\n{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}\n```\n',
    'ok_quote': b'I read "a.php" first. {"verdict":"approve","summary":"ok","findings":[]}',
    'ok_rc': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}',
    'ok_rc2': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"major","confidence":5,"message":"A real bug","suggestion":null},{"file":"a.php","line":2,"severity":"minor","confidence":5,"message":"A small issue","suggestion":null}]}',
    'prose_blocker': b'Found a blocker: SQL injection at a.php line 1. Fixed in my head.\n{"verdict":"approve","summary":"ok","findings":[]}',
    'scalar': b'42',
    'split_two': b'Review: {"summary":"s","verdict"\n:"request_changes","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}\n{"verdict":"approve","summary":"ok","findings":[]}',
    'sq_noword': b'{\'summary\':\'bad\',\'findings\':[{\'file\':\'a.php\',\'severity\':\'blocker\'}]}\n{"verdict":"approve","summary":"ok","findings":[]}',
    'sq_two': b'{\'verdict\':\'request_changes\',\'summary\':\'issue\',\'findings\':[{\'file\':\'a.php\',\'line\':1,\'severity\':\'blocker\',\'confidence\':5,\'message\':\'fix it\',\'suggestion\':null}]}\n{"verdict":"approve","summary":"ok","findings":[]}',
    'trunc_ff': b'Intro {"findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}],"summary":"blocked",\n{"verdict":"approve","summary":"ok","findings":[]}',
    'trunc_nonarr': b'{"findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}],"summary":"bad",{"verdict":"approve","summary":"ok","findings":[]}',
    'trunc_noverdict': b'Here is what I found: {"summary":"bad","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}\n{"verdict":"approve","summary":"ok","findings":[]}',
    'two_lines': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}\n{"verdict":"approve","summary":"ok","findings":[]}',
    'two_oneline': b'{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"blocker","confidence":5,"message":"A real bug","suggestion":null}]}{"verdict":"approve","summary":"ok","findings":[]}',
    'uni_ok': b'Pr\xc3\xbcfe caf\xc3\xa9 jetzt. {"verdict":"approve","summary":"\xc3\xb1 ok","findings":[]}',
    'upper_word': b'Final VERDICT: request_changes {"verdict":"approve","summary":"ok","findings":[]}',
    'word_finding': b'One finding: a.php has SQL injection. {"verdict":"approve","summary":"ok","findings":[]}',
    'word_major': b'A major bug in a.php. {"verdict":"approve","summary":"ok","findings":[]}',
    'word_severity': b'Severity high in a.php. {"verdict":"approve","summary":"ok","findings":[]}',
    'yaml_ff': b'findings:\n  - file: a.php\n    line: 1\n    severity: blocker\n    confidence: 5\n    message: SQL injection\n\n{"verdict":"approve","summary":"ok","findings":[]}',
    'yaml_noword': b'summary: SQL injection in a.php\nfindings:\n  - file: a.php\n    line: 1\n    severity: blocker\n{"verdict":"approve","summary":"ok","findings":[]}',
    'yaml_two': b'verdict: request_changes\nfindings: a.php blocker\n{"verdict":"approve","summary":"ok","findings":[]}',
}
for n, b in CASES.items():
    with open(os.path.join(d, n + ".txt"), "wb") as f:
        f.write(b)
PYEOF
}
build_cases
NCASES="$(find "$CASES_DIR" -maxdepth 1 -name '*.txt' | wc -l)"

# ---------------------------------------------------------------------------
# The stub. ONE file, symlinked to grok/agy/codex/php; it acts by its own name.
# It logs its argv, saves stdin and the env flags it saw, then plays its
# scenario file ($HOME/<name>.scn, key=value). A catalogue call (grok models /
# agy ... models) uses the same keys with a `models_` prefix. It SLEEPS first,
# then prints (TESTPLAN rev 7). $HOME is the row's temp project.
# ---------------------------------------------------------------------------
write_stub() {
    local T="$1"
    cat > "$T/bin/.stub" <<'STUB'
#!/usr/bin/env bash
name="$(basename "$0")"
T="$HOME"
scn="$T/$name.scn"

# call log: name<TAB>arg1<TAB>arg2...
{ printf '%s' "$name"; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$T/calls"

# per-name call index + saved stdin + the working directory of this call
i=$(cat "$T/.$name.n" 2>/dev/null || echo 0); i=$((i + 1)); printf '%s\n' "$i" > "$T/.$name.n"
cat > "$T/$name.stdin.$i"
pwd > "$T/$name.cwd.$i"
# any claude raw answer file ANYWHERE in the repo when this call starts (seat isolation, L-PRIVATE)
find "$T" \( -name claude.out -o -name claude.err \) -print > "$T/$name.peek.$i" 2>/dev/null

# the env the hook passed this call
printf 'REVIEW_DISABLE=%s GROK_CLAUDE_AGENTS_ENABLED=%s GROK_CLAUDE_SKILLS_ENABLED=%s GROK_CLAUDE_MCPS_ENABLED=%s GROK_CLAUDE_HOOKS_ENABLED=%s\n' \
    "${REVIEW_DISABLE-}" "${GROK_CLAUDE_AGENTS_ENABLED-}" "${GROK_CLAUDE_SKILLS_ENABLED-}" "${GROK_CLAUDE_MCPS_ENABLED-}" "${GROK_CLAUDE_HOOKS_ENABLED-}" >> "$T/$name.env"

# catalogue vs run
iscat=0
case "$name" in
    grok) [ "${1-}" = models ] && iscat=1 ;;
    agy)  for a in "$@"; do [ "$a" = models ] && iscat=1; done ;;
esac
p=""; [ "$iscat" = 1 ] && p="models_"
# A per-call override `call<i>_<field>=...` (i = this leg's 1-based call index,
# from "$T/.$name.n" above) wins over the generic `<field>`, so a scenario can
# make the Nth call of a leg behave differently (e.g. codex fails calls 1-2 then
# returns a verdict on call 3). Unset overrides fall through unchanged, so every
# existing single-scenario row is unaffected.
v() {
    local _cv
    _cv="$(sed -n "s/^call${i}_$p$1=//p" "$scn" 2>/dev/null | head -1)"
    [ -n "$_cv" ] && { printf '%s' "$_cv"; return; }
    sed -n "s/^$p$1=//p" "$scn" 2>/dev/null | head -1
}

slp="$(v sleep)";      : "${slp:=0}"
rc="$(v rc)";          : "${rc:=0}"
it="$(v ignore_term)"
sof="$(v stdout_file)"
sef="$(v stderr_file)"
nostub="$(v no_stub_line)"

# sleep first; honour an ignore_term scenario (only -k KILL can end it then).
# Sleep as a background child so a TERM tears it down cleanly (no orphan sleep);
# an ignore_term stub keeps sleeping until -k's KILL (which cannot be trapped).
SPID=""
cleanup_sleep() { [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; return 0; }
if [ "$it" = 1 ]; then trap '' TERM INT; else trap 'cleanup_sleep; exit 143' TERM INT; fi
trap cleanup_sleep EXIT
if [ "$slp" != 0 ]; then sleep "$slp" & SPID=$!; wait "$SPID" 2>/dev/null; fi

# --model arg (agy init.model default) / --output-last-message target (codex)
argmodel=""; olm=""; prev=""
for a in "$@"; do
    [ "$prev" = --model ] && argmodel="$a"
    [ "$prev" = --output-last-message ] && olm="$a"
    prev="$a"
done

# stderr: an explicit file, else one stub line unless suppressed
if [ -n "$sef" ]; then cat "$sef" >&2
elif [ "$nostub" != 1 ]; then printf '%s stub\n' "$name" >&2; fi

# stdout
if [ -n "$sof" ]; then
    cat "$sof"
elif [ "$iscat" = 1 ] && [ "$name" = grok ]; then
    printf 'You are logged in with grok.com.\nDefault model: grok-4.7\n'
elif [ "$iscat" = 1 ] && [ "$name" = agy ]; then
    cat <<'CAT'
{"command":{"data":{"models":[{"id":"gemini-3.8-flash-medium"},{"id":"gemini-4-argon-medium"},{"id":"gemini-4-argon-high"},{"id":"gemini-4-argon-low"},{"id":"claude-opus-5-5-thinking"},{"id":"gpt-oss-120b-medium"}]}}}
CAT
elif [ "$name" = grok ]; then
    tf="$(v textfile)"; stop="$(v stop)"; served="$(v served)"
    : "${stop:=end_turn}"; : "${served:=grok-4.7-build}"
    txt='""'; [ -n "$tf" ] && txt="$(jq -Rs . < "$tf")"
    mu="$(printf '%s' "$served" | tr ',' '\n' | jq -R . | jq -cs 'map({(.):{}}) | add')"
    printf '{"stopReason":%s,"text":%s,"modelUsage":%s}\n' "$(jq -n --arg s "$stop" '$s')" "$txt" "$mu"
elif [ "$name" = agy ]; then
    rf="$(v respfile)"; ef="$(v errfile)"; st="$(v status)"; md="$(v model)"
    : "${st:=SUCCESS}"; : "${md:=$argmodel}"
    resp='""'; [ -n "$rf" ] && resp="$(jq -Rs . < "$rf")"
    err='null'; [ -n "$ef" ] && err="$(jq -Rs . < "$ef")"
    printf '{"event":"init","init":{"model":%s}}\n' "$(jq -n --arg m "$md" '$m')"
    printf '{"event":"result","result":{"status":%s,"response":%s,"error":%s}}\n' "$(jq -n --arg s "$st" '$s')" "$resp" "$err"
elif [ "$name" = claude ]; then
    # nest=1: act like a real nested Claude session whose Stop hook fires — run the
    # hook again with the env this call got (one level only: STUB_DEPTH). With the
    # hook's REVIEW_DISABLE=1 guard the nested run must exit at once, calling nobody.
    if [ "$(v nest)" = 1 ] && [ -z "${STUB_DEPTH-}" ]; then
        STUB_DEPTH=1 bash "$T/.claude/review/stop-gate.sh" </dev/null >"$T/nested.out" 2>&1
        echo "$?" > "$T/nested.rc"
    fi
    tf="$(v textfile)"; st="$(v subtype)"; ie="$(v is_error)"; served="$(v served)"
    : "${st:=success}"; : "${ie:=false}"; : "${served:=claude-opus-5-5}"
    txt='""'; [ -n "$tf" ] && txt="$(jq -Rs . < "$tf")"
    mu="$(printf '%s' "$served" | tr ',' '\n' | jq -R . | jq -cs 'map({(.):{}}) | add')"
    printf '{"type":"result","subtype":%s,"is_error":%s,"result":%s,"modelUsage":%s}\n' "$(jq -n --arg s "$st" '$s')" "$ie" "$txt" "$mu"
elif [ "$name" = codex ]; then
    of="$(v outfile)"
    [ -n "$of" ] && [ -n "$olm" ] && cp "$of" "$olm"
elif [ "$name" = php ]; then
    printf 'No syntax errors detected\n'
fi
exit "$rc"
STUB
    chmod +x "$T/bin/.stub"
}
# install_leg <T> <name>  -- symlink a stub into $T/bin
install_leg() { [ -d "$1/bin" ] && ln -sf .stub "$1/bin/$2" || { echo "FATAL: install_leg '$2' into '$1/bin' failed" >&2; exit 2; }; }

# ---------------------------------------------------------------------------
# A temp project: a copy of .claude/review, a queued a.php, all four reviewer
# stubs + a logging `timeout`, and sensible default scenarios (claude=approve
# "claude-ok"; grok=valid approve "ok"; agy=approve "agy-ok"; codex=approve
# "codex-ok"). Echoes $T.
# ---------------------------------------------------------------------------
mkproj() {
    # This runs in a command-substitution subshell, so a bare `exit`/`kill` here
    # cannot reliably abort the caller (SIGTERM can be masked). Instead RETURN
    # non-zero on any setup failure; every call site guards the assignment with
    # `|| exit 2` so the caller aborts before ever writing under an empty dir.
    local T; T="$(mktemp -d -p "$HARNESS_TMP")" || { echo "FATAL: mktemp -d failed in mkproj" >&2; return 1; }
    [ -n "$T" ] && [ -d "$T" ] || { echo "FATAL: mkproj got an empty/invalid temp dir" >&2; return 1; }
    mkdir -p "$T/.claude/review/prompts" "$T/.claude/.review-state" "$T/bin"
    cp "$REVIEW_SRC"/stop-gate.sh "$REVIEW_SRC"/lib.sh "$REVIEW_SRC"/config.sh \
       "$REVIEW_SRC"/ground.sh "$REVIEW_SRC"/schema.json "$T/.claude/review/" \
       || { echo "FATAL: mkproj cp of required files failed" >&2; return 1; }
    cp "$REVIEW_SRC"/prompts/*.md "$T/.claude/review/prompts/" 2>/dev/null || true
    printf '<?php echo 1;\n' > "$T/a.php"
    printf '%s\n' "$T/a.php" > "$T/.claude/.review-state/queue"

    write_stub "$T"
    install_leg "$T" claude; install_leg "$T" grok; install_leg "$T" agy; install_leg "$T" codex

    # logging timeout: records its argv, then execs the real one
    cat > "$T/bin/timeout" <<'TO'
#!/usr/bin/env bash
{ printf 'timeout'; for a in "$@"; do printf '\t%s' "$a"; done; printf '\n'; } >> "$HOME/timeouts"
exec /usr/bin/timeout "$@"
TO
    chmod +x "$T/bin/timeout"

    # default valid verdicts for each leg
    printf '{"verdict":"approve","summary":"ok","findings":[]}'      > "$T/grok_ok.json"
    printf '{"verdict":"approve","summary":"agy-ok","findings":[]}'  > "$T/agy_ok.json"
    printf '{"verdict":"approve","summary":"codex-ok","findings":[]}'> "$T/codex_ok.json"
    printf '{"verdict":"approve","summary":"claude-ok","findings":[]}' > "$T/claude_ok.json"
    printf 'textfile=%s\n' "$T/claude_ok.json" > "$T/claude.scn"
    printf 'textfile=%s\n' "$T/grok_ok.json"  > "$T/grok.scn"
    printf 'respfile=%s\n' "$T/agy_ok.json"   > "$T/agy.scn"
    printf 'outfile=%s\n'  "$T/codex_ok.json" > "$T/codex.scn"

    # Abort (via the caller's `|| exit 2`) if any setup step above left the fixture
    # incomplete — a partial $T must never reach a test row. Catches a failed
    # cp/write_stub that did not itself abort (install_leg aborts on its own).
    local _f
    for _f in "$T/.claude/review/stop-gate.sh" "$T/.claude/review/lib.sh" \
              "$T/.claude/review/config.sh" "$T/.claude/review/ground.sh" \
              "$T/.claude/review/schema.json" "$T/a.php" \
              "$T/.claude/.review-state/queue" \
              "$T/bin/claude" "$T/bin/grok" "$T/bin/agy" "$T/bin/codex" "$T/bin/timeout"; do
        [ -e "$_f" ] || { echo "FATAL: mkproj setup incomplete, missing $_f" >&2; return 1; }
    done
    echo "$T"
}

# echo the single JSON object on stdin, or fail (non-zero) if the input is not
# EXACTLY one object — rejects a valid object followed by debug text (jq alone
# would read only the first value) and rejects two concatenated objects.
single_obj() { jq -ec -s 'if length==1 and (.[0]|type=="object") then .[0] else error("not one object") end' 2>/dev/null; }

# Run the hook in a clean env. Extra args are VAR=val pairs for `env -i`.
# Sets HOOK_OUT, HOOK_RC, HOOK_ERR, WALL and SM/DEC/RSN (parsed hook JSON).
run_hook() {
    local T="$1"; shift
    local t0 t1
    t0="$(date +%s.%N)"
    HOOK_OUT="$(printf '{}' | env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" LANG=en_US.UTF-8 "$@" bash "$T/.claude/review/stop-gate.sh" 2> "$T/hook.err")"
    HOOK_RC=$?
    t1="$(date +%s.%N)"
    HOOK_ERR="$(cat "$T/hook.err" 2>/dev/null)"
    WALL="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b - a}')"
    # The hook must print EXACTLY ONE JSON object (or nothing, for the no-leg
    # exit). Validate the WHOLE output: jq reading only the first value would
    # accept a valid object followed by debug text, so a regression that appended
    # output would still pass. Malformed non-empty output → sentinel fields so any
    # row asserting on SM/DEC/RSN FAILS.
    local _hj
    if [ -z "$HOOK_OUT" ]; then
        SM=""; DEC=""; RSN=""
    elif _hj="$(printf '%s' "$HOOK_OUT" | single_obj)"; then
        SM="$(printf '%s' "$_hj" | jq -r '.systemMessage // empty')"
        DEC="$(printf '%s' "$_hj" | jq -r '.decision // empty')"
        RSN="$(printf '%s' "$_hj" | jq -r '.reason // empty')"
    else
        SM="__BADJSON__"; DEC="__BADJSON__"; RSN="__BADJSON__"
    fi
    # The hook blocks ONLY through the JSON "decision" and always exits 0. A Stop
    # hook that exits 2 is itself a block in Claude Code, so a fail-open row that
    # checked only DEC would pass a hook that warns and then traps the turn. Every
    # run checks it here (reported only when wrong, to keep the log readable).
    [ "$HOOK_RC" = 0 ] || rep 0 L-HOOKRC "hook exited $HOOK_RC, not 0 (exit 2 blocks the Stop event)" 0
}
STATE() { printf '%s' "$1/.claude/.review-state"; }   # STATE <T>
OUTF()  { printf '%s' "$1/.claude/.review-state/verdict.json"; }

# call-log helpers over $T/calls (name<TAB>argv...)
callseq() {   # the call sequence as "grok models, grok, agy models, agy, codex"
    [ -f "$1" ] || return 0
    awk -F'\t' '{n=$1;c=0;for(i=2;i<=NF;i++)if($i=="models")c=1; if(c)print n" models"; else print n}' "$1" \
        | paste -sd'|' - | sed 's/|/, /g'
}
nruns()  { [ -f "$2" ] || { echo 0; return; }; awk -F'\t' -v n="$1" '$1==n{c=0;for(i=2;i<=NF;i++)if($i=="models")c=1; if(!c)r++} END{print r+0}' "$2"; }
ncat()   { [ -f "$2" ] || { echo 0; return; }; awk -F'\t' -v n="$1" '$1==n{c=0;for(i=2;i<=NF;i++)if($i=="models")c=1; if(c)r++} END{print r+0}' "$2"; }
ncalls() { [ -f "$2" ] || { echo 0; return; }; awk -F'\t' -v n="$1" '$1==n{r++} END{print r+0}' "$2"; }
# the run-call argv of leg $1 (first non-catalogue call), TAB-separated
runargv(){ [ -f "$2" ] || return 0; awk -F'\t' -v n="$1" '$1==n{c=0;for(i=2;i<=NF;i++)if($i=="models")c=1; if(!c){print;exit}}' "$2"; }
argvhas(){ case "$(printf '\t%s\t' "$1")" in *"$(printf '\t%s\t' "$2")"*) echo 1 ;; *) echo 0 ;; esac; }

cleanup_all() { rm -rf "$HARNESS_TMP" 2>/dev/null; }
trap cleanup_all EXIT

# ===========================================================================
# SELF ROWS (scaffolding; a SELF failure voids every later row)
# ===========================================================================
self_rows() {
    local T
    T="$(mkproj)" || exit 2
    # SELF-1: no real reviewer CLI is reachable on the row PATH
    local g a c
    g="$(env -i PATH="$T/bin:/usr/bin:/bin" bash -c 'command -v grok' 2>/dev/null)"
    a="$(env -i PATH="$T/bin:/usr/bin:/bin" bash -c 'command -v agy'  2>/dev/null)"
    c="$(env -i PATH="$T/bin:/usr/bin:/bin" bash -c 'command -v codex' 2>/dev/null)"
    rep 1 SELF-1 "no real grok on the row PATH" "$(bool test "$g" = "$T/bin/grok")"
    rep 1 SELF-1 "no real agy on the row PATH"  "$(bool test "$a" = "$T/bin/agy")"
    rep 1 SELF-1 "no real codex on the row PATH" "$(bool test "$c" = "$T/bin/codex")"
    local cl; cl="$(env -i PATH="$T/bin:/usr/bin:/bin" bash -c 'command -v claude' 2>/dev/null)"
    rep 1 SELF-1 "no real claude on the row PATH" "$(bool test "$cl" = "$T/bin/claude")"
    # SELF-2 already implied; assert each resolves to the stub dir
    rep 1 SELF-2 "grok resolves to the stub"  "$(has "$g" "$T/bin/grok")"
    rep 1 SELF-2 "agy resolves to the stub"   "$(has "$a" "$T/bin/agy")"
    rep 1 SELF-2 "codex resolves to the stub" "$(has "$c" "$T/bin/codex")"
    # SELF-3: a stub plays its scenario (direct call, not via the hook)
    local out
    out="$(env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" grok 2>/dev/null </dev/null)"
    rep 1 SELF-3 "grok stub plays its scenario" "$(bool test "$(printf '%s' "$out" | jq -r '.stopReason' 2>/dev/null)" = end_turn)"
    out="$(env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" agy --output-format json models 2>/dev/null </dev/null)"
    rep 1 SELF-3 "agy stub catalogue" "$(bool test "$(printf '%s' "$out" | jq -r '.command.data.models[0].id' 2>/dev/null)" = gemini-3.8-flash-medium)"
    out="$(env -i HOME="$T" PATH="$T/bin:/usr/bin:/bin" claude 2>/dev/null </dev/null)"
    rep 1 SELF-3 "claude stub plays its scenario" "$(bool test "$(printf '%s' "$out" | jq -r '.subtype' 2>/dev/null)" = success)"
    # SELF-4: the locale + the [0-9] Arabic-Indic match the guard rows rely on
    rep 1 SELF-4 "en_US.utf8 locale exists" "$(bool grep -qi 'en_US.utf8' <(locale -a 2>/dev/null))"
    rep 1 SELF-4 "[0-9] matches an Arabic-Indic digit under en_US.UTF-8" \
        "$(env -i LANG=en_US.UTF-8 bash -c '[[ ٣ =~ [0-9] ]]' >/dev/null 2>&1 && echo 1 || echo 0)"
    # SELF-5: a caller's REVIEW_DISABLE=1 does not reach the hook (env -i isolation).
    # It checks the HARNESS only: the hook is replaced by a probe that records what
    # it sees, so a wrong product (one that never calls a reviewer) cannot fail it.
    T="$(mkproj)" || exit 2
    printf '%s\n' 'printf "%s" "${REVIEW_DISABLE-unset}" > "$HOME/disable.seen"' > "$T/.claude/review/stop-gate.sh"
    ( export REVIEW_DISABLE=1; run_hook "$T" )
    rep 1 SELF-5 "a caller's REVIEW_DISABLE=1 does not reach the hook" "$(bool test "$(cat "$T/disable.seen" 2>/dev/null)" = unset)"
    rm -rf "$T"
    # SELF-6: the parser-input table is complete
    rep 1 SELF-6 "the 70 parser inputs exist" "$(bool test "$NCASES" = 70)"
    # SELF-7: the run_hook system PATH (/usr/bin:/bin) must NOT contain a real
    # reviewer, or a row that removes a stub would run the real tool instead of
    # exercising absence. grok/agy/codex live in ~/.local/bin or ~/.nvm, not here.
    local leaked=0 rl
    for rl in claude grok agy codex; do PATH="/usr/bin:/bin" command -v "$rl" >/dev/null 2>&1 && leaked=1; done
    rep 1 SELF-7 "no real reviewer on the run_hook system PATH" "$(bool test "$leaked" = 0)"
    # SELF-8: run_hook's single_obj gate — a row must not pass when the hook
    # appends debug text after valid JSON, or emits two objects.
    rep 1 SELF-8 "single_obj: one object accepted"             "$(printf '{"a":1}'    | single_obj >/dev/null 2>&1 && echo 1 || echo 0)"
    rep 1 SELF-8 "single_obj: object + trailing text rejected" "$(printf '{"a":1}\nx' | single_obj >/dev/null 2>&1 && echo 0 || echo 1)"
    rep 1 SELF-8 "single_obj: two objects rejected"            "$(printf '{}{}'       | single_obj >/dev/null 2>&1 && echo 0 || echo 1)"
    rep 1 SELF-8 "single_obj: empty rejected"                  "$(printf ''           | single_obj >/dev/null 2>&1 && echo 0 || echo 1)"
}

self_rows

# ---- more helpers (call log, argv, timeout log) ----------------------------
argval()      { awk -F'\t' -v f="$2" '{for(i=1;i<NF;i++) if($i==f){print $(i+1); exit}}' <<<"$1"; }
modelarg()    { argval "$(runargv agy "$1")" --model; }
printtimeout(){ local v; v="$(argval "$(runargv agy "$1")" --print-timeout)"; v="${v%s}"; printf '%s' "${v:-0}"; }
runlimit()    { [ -f "$1" ] || { echo 0; return; }; awk -F'\t' -v leg="$2" '$5==leg{c=0;for(i=6;i<=NF;i++)if($i=="models")c=1; if(!c){print $4;f=1;exit}} END{if(!f)print 0}' "$1"; }
catlimit()    { [ -f "$1" ] || { echo 0; return; }; awk -F'\t' -v leg="$2" '$5==leg{c=0;for(i=6;i<=NF;i++)if($i=="models")c=1; if(c){print $4;f=1;exit}} END{if(!f)print 0}' "$1"; }
groundlimit() { [ -f "$1" ] || { echo 0; return; }; awk -F'\t' '{g=0;for(i=1;i<=NF;i++)if($i ~ /ground\.sh$/)g=1; if(g){print $4;f=1;exit}} END{if(!f)print 0}' "$1"; }
logline_ts()  { [ -f "$1" ] || return 0; sed 's/^[^ ]* //' "$1"; }   # review.log, timestamp stripped
limits_pos()  { [ -f "$1" ] || return 0; awk -F'\t' '{for(i=1;i<=NF;i++) if($i=="-k"){v=$(i+2)+0; if(v<=0){print "BAD";exit}}}' "$1"; }  # empty = all > 0
oneline()     { case "$1" in *$'\n'*) echo 0 ;; *) echo 1 ;; esac; }

# the measured grok 402 (rc 1) -> grok.scn
grok402() {
    local T="$1" msg
    msg=$'Internal error: {\n  "message": "API error (status 402 Payment Required): Grok Build usage balance exhausted",\n  "http_status": 402\n}'
    jq -cn --arg m "$msg" --arg c "$T" '{type:"error",message:$m,cwd:$c}' > "$T/grok402.json"
    printf 'Error: %s\n' "$msg" > "$T/grok402.err"
    { echo "rc=1"; echo "stdout_file=$T/grok402.json"; echo "stderr_file=$T/grok402.err"; echo "no_stub_line=1"; } > "$T/grok.scn"
}
# agy 429 (rc 3, status ERROR, a Resets-in error) -> agy.scn
agy429() {
    local T="$1"
    printf 'Individual quota reached. Resets in 149h43m.' > "$T/agy429.err"
    { echo "rc=3"; echo "status=ERROR"; echo "errfile=$T/agy429.err"; } > "$T/agy.scn"
}
# make the codex RUN fail fast (rc 1, one "codex" call logged). Needed to reach a
# fallback for seat 2, because codex answers OK by default.
codexfail() { echo "rc=1" > "$1/codex.scn"; }
# make the claude (seat 1) RUN fail fast (rc 1), so seat 1 needs a fallback too.
claudefail() { echo "rc=1" > "$1/claude.scn"; }
# write a verdict JSON file: vfile <path> <verdict> <findings-json>
vfile() { printf '{"verdict":"%s","summary":"blocked","findings":%s}' "$2" "$3" > "$1"; }
F_MAJOR5='[{"file":"a.php","line":1,"severity":"major","confidence":5,"message":"r1bug","suggestion":null}]'
F_MINOR5='[{"file":"a.php","line":1,"severity":"minor","confidence":5,"message":"small","suggestion":null}]'

NARR="I'll start by reading the brief..."

# ===========================================================================
# L-PARSE: each frozen input is grok's .text; KEPT -> grok's verdict used,
# INVALID -> the parser rejects it and agy answers (AC7, R3/R3b/R3c/R3d).
# ===========================================================================
classify() {   # echoes "B <n>" (block), "A" (approve) or "I" (invalid)
    case "$1" in
        ok_rc2) echo "B 2" ;;
        blank_fence|colon_ok|fence_crlf|fence_crlf_open|lim_verdictword|measured|ok_crlf|ok_esckey|ok_escq|ok_fence|ok_rc) echo "B 1" ;;
        lim_critical|lim_rcprose|lim_word|majority|md_ff|ml_draft|ok_ap|ok_apos|ok_quote|prose_blocker|uni_ok|upper_word|word_finding|word_major|word_severity|yaml_ff|yaml_noword|yaml_two) echo "A" ;;
        *) echo "I" ;;
    esac
}
parse_one_row() {
    local n="$1" T cls kind nf calls vj c
    sel "L-PARSE/$n" || return 0
    T="$(mkproj)" || exit 2
    rm -f "$T/bin/codex"        # drop codex so grok fills seat 2 and its answer is parsed (claude approves seat 1)
    printf 'textfile=%s\n' "$CASES_DIR/$n.txt" > "$T/grok.scn"
    run_hook "$T"
    calls="$T/calls"; vj="$(OUTF "$T")"
    cls="$(classify "$n")"; kind="${cls%% *}"; nf="${cls##* }"
    if [ "$kind" = B ]; then
        c=0; [ "$DEC" = block ] && [ "$(has "$RSN" "🔍 grok review (round 1) requested changes")" = 1 ] && c=1
        rep 0 "L-PARSE/$n" "kept: block naming grok" "$c"
        c=0; [ "$(jq -r '.verdict' "$vj" 2>/dev/null)" = request_changes ] && [ "$(jq -r '.findings|length' "$vj" 2>/dev/null)" = "$nf" ] && c=1
        rep 0 "L-PARSE/$n" "kept: verdict.json = the answer" "$c"
        rep 0 "L-PARSE/$n" "kept: agy not run" "$(bool test "$(ncalls agy "$calls")" = 0)"
    elif [ "$kind" = A ]; then
        rep 0 "L-PARSE/$n" "kept: grok's approve" "$(has "$SM" "✅ grok review passed")"
        c=0; [ "$(jq -r '.verdict' "$vj" 2>/dev/null)" = approve ] && [ "$(jq -r '.findings|length' "$vj" 2>/dev/null)" = 0 ] && c=1
        rep 0 "L-PARSE/$n" "kept: verdict.json = the answer" "$c"
        rep 0 "L-PARSE/$n" "kept: agy not run" "$(bool test "$(ncalls agy "$calls")" = 0)"
    else
        rep 0 "L-PARSE/$n" "invalid: agy used" "$(bool test "$(nruns agy "$calls")" = 1)"
        rep 0 "L-PARSE/$n" "invalid: no grok verdict" "$(has "$SM" "grok: invalid verdict")"
        [ "$n" = big ] && rep 0 "L-PARSE/$n" "big: wall ${WALL}s < 5" "$(awk -v w="$WALL" 'BEGIN{print (w<5)?1:0}')"
    fi
    rm -rf "$T"
}
parse_rows() {
    local n kept=() inv=()
    for n in "$CASES_DIR"/*.txt; do n="$(basename "$n" .txt)"
        case "$(classify "$n")" in I) inv+=("$n") ;; *) kept+=("$n") ;; esac
    done
    mapfile -t kept < <(printf '%s\n' "${kept[@]}" | sort)
    mapfile -t inv  < <(printf '%s\n' "${inv[@]}"  | sort)
    for n in "${kept[@]}" "${inv[@]}"; do parse_one_row "$n"; done
}
parse_rows

# ---- L-PARSE-agy / L-PARSE-codex: the parser runs for every leg (tp-r1 X F2)
parse_through() {
    local n T vj c
    for n in two_lines dup_lit jslit f2bad measured; do
        # agy path: claude + codex down, grok 402, input is agy's response (agy fills seat 1)
        if sel "L-PARSE-agy/$n"; then
            T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"
            printf 'respfile=%s\n' "$CASES_DIR/$n.txt" > "$T/agy.scn"
            run_hook "$T"
            if [ "$n" = measured ]; then
                c=0; [ "$DEC" = block ] && [ "$(has "$RSN" "🔍 agy review (round 1) requested changes")" = 1 ] && c=1
                rep 0 "L-PARSE-agy/$n" "kept: block naming agy" "$c"
            else
                # claude, codex and grok (402) all fail, so an agy rejection leaves both
                # seats empty -> fail-open.
                c=0; [ "$(has "$SM" "No reviewer could run")" = 1 ] && [ "$(has "$SM" "agy: invalid verdict")" = 1 ] && c=1
                rep 0 "L-PARSE-agy/$n" "invalid: fail-open, agy: invalid verdict" "$c"
            fi
            rm -rf "$T"
        fi
        # codex path: claude down, grok 402, agy 429, input is codex's -o file
        if sel "L-PARSE-codex/$n"; then
            T="$(mkproj)" || exit 2; claudefail "$T"; grok402 "$T"; agy429 "$T"
            printf 'outfile=%s\n' "$CASES_DIR/$n.txt" > "$T/codex.scn"
            run_hook "$T"; vj="$(OUTF "$T")"
            if [ "$n" = measured ]; then
                c=0; [ "$DEC" = block ] && [ "$(has "$RSN" "🔍 codex review (round 1) requested changes")" = 1 ] && c=1
                rep 0 "L-PARSE-codex/$n" "kept: block naming codex" "$c"
            else
                c=0; [ "$(has "$SM" "No reviewer could run")" = 1 ] && [ "$(has "$SM" "codex: invalid verdict")" = 1 ] && c=1
                rep 0 "L-PARSE-codex/$n" "invalid: fail-open, codex: invalid verdict" "$c"
            fi
            rm -rf "$T"
        fi
    done
}
parse_through

# ---- L-SHAPE / L-SHAPE-agy: schema shape, one edit per sub-row (AC7, R3) ----
SHAPE_BASE='{"verdict":"request_changes","summary":"blocked","findings":[{"file":"a.php","line":1,"severity":"minor","confidence":5,"message":"m1","suggestion":null},{"file":"a.php","line":2,"severity":"major","confidence":5,"message":"m2","suggestion":null},{"file":"a.php","line":3,"severity":"nit","confidence":5,"message":"m3","suggestion":null}]}'
SHAPE_EDITS=(
  'del(.verdict)'
  '.verdict = "maybe"'
  '.findings[1].severity = "high"'
  '.findings[1].severity = "Major"'
  '.findings[1].file = null'
  '.findings[1].confidence = "5"'
  '.findings[1].confidence = 0'
  '.findings[1].confidence = 6'
  '.findings[1].line = "3"'
  '.findings[1].line = 1.5'
  '.findings[1].confidence = 4.5'
  '.findings[1] = "a string"'
  '.findings = "none"'
  'del(.summary)'
  '.summary = null'
  '.findings[1].message = 3'
  '.findings[1].suggestion = 3'
  '.findings += [.findings[1] | .severity = "high"]'
  '.findings[1].line = null'
  '.findings[1].suggestion = null'
)
shape_kept() { case "$1" in '.findings[1].line = null'|'.findings[1].suggestion = null') return 0 ;; *) return 1 ;; esac; }
shape_rows() {
    local e T c bf
    for e in "${SHAPE_EDITS[@]}"; do
        bf="$(printf '%s' "$SHAPE_BASE" | jq -c "$e")"
        # L-SHAPE: grok narration + the edited body; agy-ok
        if sel "L-SHAPE/$e"; then
            T="$(mkproj)" || exit 2
            rm -f "$T/bin/codex"        # drop codex so grok fills seat 2 for this shape check
            printf '%s%s' "$NARR" "$bf" > "$T/shape.txt"
            printf 'textfile=%s\n' "$T/shape.txt" > "$T/grok.scn"
            run_hook "$T"
            if shape_kept "$e"; then
                c=0; [ "$DEC" = block ] && [ "$(has "$RSN" "🔍 grok review (round 1) requested changes")" = 1 ] && c=1
                rep 0 "L-SHAPE/$e" "kept: block naming grok" "$c"
            else
                rep 0 "L-SHAPE/$e" "agy used" "$(bool test "$(nruns agy "$T/calls")" = 1)"
            fi
            rm -rf "$T"
        fi
        # L-SHAPE-agy: no narration, as agy's response; claude + codex down; grok 402
        if sel "L-SHAPE-agy/$e"; then
            T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"
            printf '%s' "$bf" > "$T/shape.txt"
            printf 'respfile=%s\n' "$T/shape.txt" > "$T/agy.scn"
            run_hook "$T"
            if shape_kept "$e"; then
                c=0; [ "$DEC" = block ] && [ "$(has "$RSN" "🔍 agy review (round 1) requested changes")" = 1 ] && c=1
                rep 0 "L-SHAPE-agy/$e" "kept: block naming agy" "$c"
            else
                c=0; [ "$(has "$SM" "No reviewer could run")" = 1 ] && [ "$(has "$SM" "agy: invalid verdict")" = 1 ] && c=1
                rep 0 "L-SHAPE-agy/$e" "invalid: fail-open, agy: invalid verdict" "$c"
            fi
            rm -rf "$T"
        fi
    done
}
shape_rows

# ===========================================================================
# Leg-loop rows: order, fallback, per-leg validity gates, state, time budget,
# argv, env, docs/settings (AC1-AC9).
# ===========================================================================
seed_out() { mkdir -p "$(STATE "$1")"; printf '%s' "$2" > "$(OUTF "$1")"; }
rnd()      { cat "$(STATE "$1")/round" 2>/dev/null; }
ncalls_safe(){ [ -f "$2" ] && ncalls "$1" "$2" || echo 0; }
# a big grok error message: "Internal error:" + 60x(sp,tab,nl) + "API error ..." + 200 x
bigmsg() { { printf 'Internal error:'; printf ' \t\n%.0s' $(seq 1 60)
            printf 'API error (status 402 Payment Required) '; printf 'x%.0s' $(seq 1 200); } > "$1/bigmsg.txt"; }
grok_bigerr() { bigmsg "$1"
    jq -Rs --arg c "$1" '{type:"error",message:.,cwd:$c}' < "$1/bigmsg.txt" > "$1/grokbig.json"
    { echo "rc=1"; echo "stdout_file=$1/grokbig.json"; echo "no_stub_line=1"; } > "$1/grok.scn"; }
guard_exp() { case "$1" in 30) echo 10 ;; 090) echo 30 ;; *) echo 180 ;; esac; }
reason_valid() {   # a one-line, collapsed, 160-char cut of the big message
    local m="$1"
    [ "$(oneline "$m")" = 1 ] && [ "${#m}" = 160 ] && [ "$(has "$m" "Required) x")" = 1 ] \
        && case "$m" in "Internal error: API error (status 402 Payment Required) "*) return 0 ;; *) return 1 ;; esac
}

leg_rows() {
  local T r calls S exp line mcut v envline

  # ---- L-ORDER: seat 1 claude, seat 2 codex; both answer, nothing else runs -
  if sel L-ORDER; then
    T="$(mkproj)" || exit 2; run_hook "$T"; calls="$T/calls"
    rep 0 L-ORDER "calls: claude, codex" "$(bool test "$(callseq "$calls")" = "claude, codex")"
    rep 0 L-ORDER "one claude, one codex, no grok, no agy" "$(bool test "$(ncalls claude "$calls")/$(ncalls codex "$calls")/$(ncalls grok "$calls")/$(ncalls agy "$calls")" = 1/1/0/0)"
    rep 0 L-ORDER "note names both seats in order" "$(has "$SM" "✅ claude review passed: claude-ok | ✅ codex review passed: codex-ok")"
    rep 0 L-ORDER "no one-reviewer warning" "$(bool test "$(has "$SM" "only one reviewer ran")" = 0)"
    rep 0 L-ORDER "verdict.json combines both seats" "$(bool test "$(jq -c '[.verdict,.summary,(.findings|length)]' "$(OUTF "$T")" 2>/dev/null)" = '["approve","claude: claude-ok | codex: codex-ok",0]')"
    rm -rf "$T"
  fi

  # ---- L-402: claude down, grok 402 -> agy fills seat 1 ---------------------
  if sel L-402; then
    T="$(mkproj)" || exit 2; claudefail "$T"; grok402 "$T"; run_hook "$T"
    rep 0 L-402 "calls: claude, codex, grok models, grok, agy models, agy" "$(bool test "$(callseq "$T/calls")" = "claude, codex, grok models, grok, agy models, agy")"
    rep 0 L-402 "note names agy and carries the 402" "$(bool test "$(has "$SM" "agy review passed")$(has "$SM" 402)" = 11)"
    rep 0 L-402 "note is one line" "$(oneline "$SM")"
    rm -rf "$T"
  fi

  # ---- L-GROKFAIL/*: claude down; each grok-gate rejection falls to agy -----
  if sel 'L-GROKFAIL/cancel'; then
    T="$(mkproj)" || exit 2; claudefail "$T"; { echo "stop=cancelled"; echo "textfile=$T/grok_ok.json"; } > "$T/grok.scn"; run_hook "$T"
    rep 0 L-GROKFAIL/cancel "agy used (stopReason not end_turn)" "$(bool test "$(nruns agy "$T/calls")" = 1)"; rm -rf "$T"
  fi
  if sel 'L-GROKFAIL/empty'; then
    T="$(mkproj)" || exit 2; claudefail "$T"; : > "$T/empty.txt"; echo "textfile=$T/empty.txt" > "$T/grok.scn"; run_hook "$T"
    rep 0 L-GROKFAIL/empty "agy used" "$(bool test "$(nruns agy "$T/calls")" = 1)"
    rep 0 L-GROKFAIL/empty "note: grok: empty text" "$(has "$SM" "grok: empty text")"; rm -rf "$T"
  fi
  if sel 'L-GROKFAIL/jsonerr'; then
    T="$(mkproj)" || exit 2; claudefail "$T"; printf 'not json at all\n' > "$T/nj.txt"
    jq -cn --rawfile t "$T/grok_ok.json" '{stopReason:"end_turn",text:$t,modelUsage:{"grok-4.7-build":{}}}' > "$T/stderrbody"
    { echo "rc=0"; echo "stdout_file=$T/nj.txt"; echo "stderr_file=$T/stderrbody"; echo "no_stub_line=1"; } > "$T/grok.scn"; run_hook "$T"
    rep 0 L-GROKFAIL/jsonerr "agy used (stdout not JSON)" "$(bool test "$(nruns agy "$T/calls")" = 1)"
    rep 0 L-GROKFAIL/jsonerr "note: grok: not JSON" "$(has "$SM" "grok: not JSON")"; rm -rf "$T"
  fi
  if sel 'L-GROKFAIL/rc1'; then
    T="$(mkproj)" || exit 2; claudefail "$T"; { echo "rc=1"; echo "textfile=$T/grok_ok.json"; } > "$T/grok.scn"; run_hook "$T"
    rep 0 L-GROKFAIL/rc1 "agy used" "$(bool test "$(nruns agy "$T/calls")" = 1)"
    rep 0 L-GROKFAIL/rc1 "note: grok: exit 1" "$(has "$SM" "grok: exit 1")"; rm -rf "$T"
  fi
  if sel 'L-GROKFAIL/served-old'; then
    T="$(mkproj)" || exit 2; claudefail "$T"; { echo "served=grok-4.6-build"; echo "textfile=$T/grok_ok.json"; } > "$T/grok.scn"; run_hook "$T"
    rep 0 L-GROKFAIL/served-old "agy used (served != default prefix)" "$(bool test "$(nruns agy "$T/calls")" = 1)"; rm -rf "$T"
  fi
  if sel 'L-GROKFAIL/served-two'; then
    T="$(mkproj)" || exit 2; claudefail "$T"; { echo "served=grok-4.7-build,grok-4.7-build-fast"; echo "textfile=$T/grok_ok.json"; } > "$T/grok.scn"; run_hook "$T"
    rep 0 L-GROKFAIL/served-two "agy used (two modelUsage keys)" "$(bool test "$(nruns agy "$T/calls")" = 1)"; rm -rf "$T"
  fi
  if sel 'L-GROKFAIL/prose'; then
    T="$(mkproj)" || exit 2; claudefail "$T"; printf 'I reviewed it, looks fine.\n' > "$T/prose.txt"; echo "textfile=$T/prose.txt" > "$T/grok.scn"; run_hook "$T"
    rep 0 L-GROKFAIL/prose "agy used (prose, no JSON)" "$(bool test "$(nruns agy "$T/calls")" = 1)"; rm -rf "$T"
  fi

  # ---- L-NODEFAULT: claude down; grok models prints no default -> no grok run
  if sel L-NODEFAULT; then
    T="$(mkproj)" || exit 2; claudefail "$T"; printf 'You are logged in with grok.com.\n' > "$T/nocat.txt"
    { echo "models_stdout_file=$T/nocat.txt"; echo "textfile=$T/grok_ok.json"; } > "$T/grok.scn"; run_hook "$T"
    rep 0 L-NODEFAULT "no grok run" "$(bool test "$(nruns grok "$T/calls")" = 0)"
    rep 0 L-NODEFAULT "agy used" "$(bool test "$(nruns agy "$T/calls")" = 1)"
    rep 0 L-NODEFAULT "note: no default model" "$(has "$SM" "no default model")"; rm -rf "$T"
  fi

  # ---- L-AGY429 / L-AGYEMPTY / L-AGYRC: codex + grok down, so an agy-gate ---
  #      rejection has no working leg after it -> the hook fails open ---------
#      (claude and codex both down too: no seat is filled)
  if sel L-AGY429; then
    T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"; agy429 "$T"; run_hook "$T"
    rep 0 L-AGY429 "calls: claude, codex, grok models, grok, agy models, agy" "$(bool test "$(callseq "$T/calls")" = "claude, codex, grok models, grok, agy models, agy")"
    rep 0 L-AGY429 "fail-open naming grok's 402 and agy's exit 3" "$(bool test "$(has "$SM" "No reviewer could run")$(has "$SM" 402)$(has "$SM" "exit 3")" = 111)"; rm -rf "$T"
  fi
  if sel L-AGYEMPTY; then
    T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"; : > "$T/er.txt"; { echo "status=SUCCESS"; echo "respfile=$T/er.txt"; } > "$T/agy.scn"; run_hook "$T"
    rep 0 L-AGYEMPTY "agy not chosen (empty response)" "$(bool test "$(has "$SM" "agy review passed")" = 0)"
    rep 0 L-AGYEMPTY "note: agy: empty response" "$(has "$SM" "agy: empty response")"
    rep 0 L-AGYEMPTY "fail-open" "$(has "$SM" "No reviewer could run")"; rm -rf "$T"
  fi
  if sel L-AGYRC; then
    T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"; { echo "rc=1"; echo "status=SUCCESS"; echo "respfile=$T/agy_ok.json"; } > "$T/agy.scn"; run_hook "$T"
    rep 0 L-AGYRC "agy not chosen" "$(bool test "$(has "$SM" "agy review passed")" = 0)"
    rep 0 L-AGYRC "note: agy: exit 1" "$(has "$SM" "agy: exit 1")"
    rep 0 L-AGYRC "fail-open" "$(has "$SM" "No reviewer could run")"; rm -rf "$T"
  fi

  # ---- L-REASON: the failure reason is one line, collapsed, cut to 160 -----
  if sel 'L-REASON/grok'; then
    T="$(mkproj)" || exit 2; claudefail "$T"; grok_bigerr "$T"; run_hook "$T"; S="$(STATE "$T")"
    line="$(logline_ts "$S/review.log" | grep -F 'grok: exit 1: ' | head -1)"; mcut="${line#grok: exit 1: }"
    rep 0 L-REASON/grok "review.log: one-line reason, collapsed and cut to 160" "$(bool reason_valid "$mcut")"
    rep 0 L-REASON/grok "note holds that exact reason" "$(has "$SM" "grok: exit 1: $mcut")"; rm -rf "$T"
  fi
  if sel 'L-REASON/agy'; then
    T="$(mkproj)" || exit 2; claudefail "$T"; bigmsg "$T"; grok402 "$T"; { echo "rc=3"; echo "status=ERROR"; echo "errfile=$T/bigmsg.txt"; } > "$T/agy.scn"; run_hook "$T"; S="$(STATE "$T")"
    line="$(logline_ts "$S/review.log" | grep -F 'agy: exit 3: ' | head -1)"; mcut="${line#agy: exit 3: }"
    rep 0 L-REASON/agy "review.log: one-line reason, collapsed and cut to 160" "$(bool reason_valid "$mcut")"
    rep 0 L-REASON/agy "note holds that exact reason" "$(has "$SM" "agy: exit 3: $mcut")"; rm -rf "$T"
  fi

  # ---- L-LOG / L-RAW: the review.log order and raw-output files ------------
  if sel L-LOG; then
    T="$(mkproj)" || exit 2; claudefail "$T"; grok402 "$T"; run_hook "$T"; S="$(STATE "$T")"
    local gln aln rln
    gln="$(grep -n 'file(s) via grok' "$S/review.log" | head -1 | cut -d: -f1)"
    rln="$(grep -n '402' "$S/review.log" | head -1 | cut -d: -f1)"
    aln="$(grep -n 'file(s) via agy'  "$S/review.log" | head -1 | cut -d: -f1)"
    rep 0 L-LOG "review.log: grok attempt, then its 402, then agy attempt" "$([ -n "$gln" ] && [ -n "$rln" ] && [ -n "$aln" ] && [ "$gln" -lt "$rln" ] && [ "$rln" -lt "$aln" ] && echo 1 || echo 0)"
    rep 0 L-LOG "review.log: the 402 body is not on its own lines" "$(bool test "$(grep -c 402 "$S/review.log")" = 1)"
    rep 0 L-LOG "review.log: the grok line is not the summary" "$(bool test "$(logline_ts "$S/review.log" | tail -1 | grep -c 'via grok')" = 0)"
    rm -rf "$T"
  fi
  if sel L-RAW; then
    T="$(mkproj)" || exit 2; claudefail "$T"; grok402 "$T"; run_hook "$T"; S="$(STATE "$T")"
    rep 0 L-RAW "grok.out, grok.err, agy.out all exist" "$(bool test -e "$S/grok.out" -a -e "$S/grok.err" -a -e "$S/agy.out")"
    rep 0 L-RAW "grok.out holds the 402" "$(has "$(cat "$S/grok.out" 2>/dev/null)" 402)"; rm -rf "$T"
  fi

  # ---- L-AGYERR0 / L-AGYMODEL / L-AGYPICK / L-AGYNOMODEL (codex + grok down) -
  if sel L-AGYERR0; then
    T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"; { printf 'the %.0s' $(seq 1 10000); cat "$T/agy_ok.json"; } > "$T/err0.txt"
    { echo "rc=0"; echo "status=ERROR"; echo "respfile=$T/err0.txt"; } > "$T/agy.scn"; run_hook "$T"
    rep 0 L-AGYERR0 "calls: claude, codex, grok models, grok, agy models, agy" "$(bool test "$(callseq "$T/calls")" = "claude, codex, grok models, grok, agy models, agy")"
    rep 0 L-AGYERR0 "note: agy status not SUCCESS" "$(has "$SM" "status not SUCCESS")"
    rep 0 L-AGYERR0 "fail-open (codex down)" "$(has "$SM" "No reviewer could run")"; rm -rf "$T"
  fi
  if sel L-AGYMODEL; then
    T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"; { echo "status=SUCCESS"; echo "model=gemini-3.8-flash-medium"; echo "respfile=$T/agy_ok.json"; } > "$T/agy.scn"; run_hook "$T"
    rep 0 L-AGYMODEL "agy not chosen (wrong model)" "$(bool test "$(has "$SM" "agy review passed")" = 0)"
    rep 0 L-AGYMODEL "note: agy served the wrong model" "$(has "$SM" "served model is not gemini-4-argon-medium")"
    rep 0 L-AGYMODEL "fail-open" "$(has "$SM" "No reviewer could run")"; rm -rf "$T"
  fi
  if sel 'L-AGYPICK/a'; then
    T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"; run_hook "$T"
    rep 0 L-AGYPICK/a "picks gemini-4-argon-medium" "$(bool test "$(modelarg "$T/calls")" = gemini-4-argon-medium)"; rm -rf "$T"
  fi
  if sel 'L-AGYPICK/b'; then
    T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"
    jq -cn '{command:{data:{models:[{id:"gemini-4.9-argon-medium"},{id:"gemini-4.10-argon-medium"},{id:"gemini-4-argon-medium"},{id:"gemini-4.10-argon-high"}]}}}' > "$T/catb.json"
    { echo "models_stdout_file=$T/catb.json"; echo "status=SUCCESS"; echo "model=gemini-4.10-argon-medium"; echo "respfile=$T/agy_ok.json"; } > "$T/agy.scn"; run_hook "$T"
    rep 0 L-AGYPICK/b "picks the highest medium: gemini-4.10-argon-medium" "$(bool test "$(modelarg "$T/calls")" = gemini-4.10-argon-medium)"; rm -rf "$T"
  fi
  if sel L-AGYNOMODEL; then
    T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"
    jq -cn '{command:{data:{models:[{id:"claude-opus-5-5-thinking"},{id:"gpt-oss-120b-medium"},{id:"gemini-4-argon-high"}]}}}' > "$T/catn.json"
    { echo "models_stdout_file=$T/catn.json"; } > "$T/agy.scn"; run_hook "$T"
    rep 0 L-AGYNOMODEL "calls: claude, codex, grok models, grok, agy models (no agy run)" "$(bool test "$(callseq "$T/calls")" = "claude, codex, grok models, grok, agy models")"
    rep 0 L-AGYNOMODEL "no agy run" "$(bool test "$(nruns agy "$T/calls")" = 0)"
    rep 0 L-AGYNOMODEL "note: no gemini medium model" "$(has "$SM" "no gemini medium model")"
    rep 0 L-AGYNOMODEL "fail-open" "$(has "$SM" "No reviewer could run")"; rm -rf "$T"
  fi

  # ---- L-ALLFAIL / L-NOGROK / L-ONLYGROK / L-NONE / L-NOCODEX --------------
  if sel L-ALLFAIL; then
    T="$(mkproj)" || exit 2; seed_out "$T" '{"verdict":"approve","summary":"SEED","findings":[]}'; cp "$(OUTF "$T")" "$T/seed.json"
    claudefail "$T"; grok402 "$T"; agy429 "$T"; echo "rc=1" > "$T/codex.scn"; run_hook "$T"
    rep 0 L-ALLFAIL "one fail-open note naming all four (claude first)" "$(bool test "$(has "$SM" "No reviewer could run (claude:")$(has "$SM" "codex:")$(has "$SM" "grok:")$(has "$SM" "agy:")$(has "$SM" "skipping this turn.")" = 11111)"
    rep 0 L-ALLFAIL "no decision" "$(bool test -z "$DEC")"
    rep 0 L-ALLFAIL "hook exit code 0 (fail-open, not exit 2)" "$(bool test "$HOOK_RC" = 0)"
    rep 0 L-ALLFAIL "verdict.json unchanged" "$(bool cmp -s "$(OUTF "$T")" "$T/seed.json")"; rm -rf "$T"
  fi
  if sel L-NOGROK; then
    # grok absent: it is simply skipped (no "not installed" note); claude down, so
    # agy fills seat 1 next to codex in seat 2.
    T="$(mkproj)" || exit 2; rm -f "$T/bin/grok"; claudefail "$T"; run_hook "$T"
    rep 0 L-NOGROK "calls: claude, codex, agy models, agy" "$(bool test "$(callseq "$T/calls")" = "claude, codex, agy models, agy")"
    rep 0 L-NOGROK "grok never called" "$(bool test "$(ncalls grok "$T/calls")" = 0)"
    rep 0 L-NOGROK "agy fills seat 1: note agy then codex" "$(has "$SM" "✅ agy review passed: agy-ok | ✅ codex review passed: codex-ok")"
    rep 0 L-NOGROK "no 'not installed' note" "$(bool test "$(has "$SM" "not installed")" = 0)"; rm -rf "$T"
  fi
  # ---- L-ONCE: every leg is tried at most once (no codex re-check any more) -
  if sel L-ONCE; then
    T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"; agy429 "$T"; run_hook "$T"
    rep 0 L-ONCE "one run each: claude/codex/grok/agy = 1/1/1/1" "$(bool test "$(ncalls claude "$T/calls")/$(ncalls codex "$T/calls")/$(nruns grok "$T/calls")/$(nruns agy "$T/calls")" = 1/1/1/1)"
    rep 0 L-ONCE "sequence claude, codex, grok models, grok, agy models, agy" "$(bool test "$(callseq "$T/calls")" = "claude, codex, grok models, grok, agy models, agy")"
    rep 0 L-ONCE "all failed -> fail-open" "$(has "$SM" "No reviewer could run")"; rm -rf "$T"
  fi
  if sel L-ONLYGROK; then
    T="$(mkproj)" || exit 2; rm -f "$T/bin/agy" "$T/bin/codex" "$T/bin/claude"; run_hook "$T" REVIEW_TIMEOUT=240
    rep 0 L-ONLYGROK "grok used" "$(bool test "$(nruns grok "$T/calls")" = 1)"
    rep 0 L-ONLYGROK "note warns only one reviewer ran" "$(has "$SM" "⚠️ only one reviewer ran")"
    rep 0 L-ONLYGROK "grok run limit >= 200 (gets the whole budget)" "$(awk -v n="$(runlimit "$T/timeouts" grok)" 'BEGIN{print (n>=200)?1:0}')"; rm -rf "$T"
  fi
  if sel L-NONE; then
    T="$(mkproj)" || exit 2; rm -f "$T/bin/claude" "$T/bin/grok" "$T/bin/agy" "$T/bin/codex"; install_leg "$T" php; run_hook "$T"
    rep 0 L-NONE "rc 0, empty output" "$(bool test "$HOOK_RC" = 0 -a -z "$HOOK_OUT")"
    rep 0 L-NONE "no prompt built" "$(bool test ! -e "$(STATE "$T")/prompt.txt")"
    rep 0 L-NONE "php not called" "$(bool test "$(ncalls_safe php "$T/calls")" = 0)"; rm -rf "$T"
  fi
  if sel L-NOCODEX; then
    T="$(mkproj)" || exit 2; rm -f "$T/bin/codex"; run_hook "$T"
    rep 0 L-NOCODEX "grok fills seat 2 (codex absence does not short-circuit)" "$(bool test "$(nruns grok "$T/calls")" = 1)"
    rep 0 L-NOCODEX "note: claude then grok" "$(has "$SM" "✅ claude review passed: claude-ok | ✅ grok review passed: ok")"; rm -rf "$T"
  fi
  if sel L-NOCLAUDE; then
    T="$(mkproj)" || exit 2; rm -f "$T/bin/claude"; run_hook "$T"
    rep 0 L-NOCLAUDE "calls: codex, grok models, grok" "$(bool test "$(callseq "$T/calls")" = "codex, grok models, grok")"
    rep 0 L-NOCLAUDE "grok fills seat 1: note grok then codex" "$(has "$SM" "✅ grok review passed: ok | ✅ codex review passed: codex-ok")"; rm -rf "$T"
  fi

  # ---- L-STALE*: the verify-only round and state across rounds -------------
  if sel L-STALE; then
    T="$(mkproj)" || exit 2; mkdir -p "$(STATE "$T")"; echo 1 > "$(STATE "$T")/round"
    vfile "$(OUTF "$T")" request_changes "$F_MAJOR5"; cp "$(OUTF "$T")" "$T/seed.json"
    claudefail "$T"; grok402 "$T"; agy429 "$T"; echo "rc=1" > "$T/codex.scn"; run_hook "$T"; S="$(STATE "$T")"
    rep 0 L-STALE "fail-open, no block" "$(bool test "$(has "$SM" "No reviewer could run")" = 1 -a -z "$DEC")"
    rep 0 L-STALE "verdict.json byte-identical" "$(bool cmp -s "$(OUTF "$T")" "$T/seed.json")"
    rep 0 L-STALE "prompt: VERIFY ONLY with the prior finding" "$(bool test "$(has "$(cat "$S/prompt.txt" 2>/dev/null)" "VERIFY ONLY")$(has "$(cat "$S/prompt.txt" 2>/dev/null)" "r1bug")" = 11)"; rm -rf "$T"
  fi
  if sel L-STALE2; then
    T="$(mkproj)" || exit 2; mkdir -p "$(STATE "$T")"; echo 1 > "$(STATE "$T")/round"
    vfile "$(OUTF "$T")" request_changes "$F_MAJOR5"; run_hook "$T"
    rep 0 L-STALE2 "released" "$(has "$SM" "codex review passed")"
    rep 0 L-STALE2 "verdict.json is the two seats', normalised" "$(bool test "$(jq -r .summary "$(OUTF "$T")" 2>/dev/null)" = "claude: claude-ok | codex: codex-ok")"; rm -rf "$T"
  fi
  if sel L-STALE3; then
    # codex down for every round, so grok fills seat 2: it drives the round-1 block
    # and the round-3 approval. Round 2 fails every leg (claude too) -> fail-open,
    # round state untouched; claude is restored for round 3.
    T="$(mkproj)" || exit 2; S="$(STATE "$T")"; codexfail "$T"
    vfile "$T/r1.json" request_changes "$F_MAJOR5"; echo "textfile=$T/r1.json" > "$T/grok.scn"; run_hook "$T"
    rep 0 L-STALE3 "round 1 blocks" "$(bool test "$DEC" = block)"
    rep 0 L-STALE3 "round file is 1" "$(bool test "$(rnd "$T")" = 1)"
    cp "$(OUTF "$T")" "$T/r1out.json"; cp "$S/queue" "$T/q1.txt"
    claudefail "$T"; grok402 "$T"; agy429 "$T"; echo "rc=1" > "$T/codex.scn"; run_hook "$T"
    rep 0 L-STALE3 "round 2 prompt carries round 1's finding" "$(has "$(cat "$S/prompt.txt" 2>/dev/null)" "r1bug")"
    rep 0 L-STALE3 "verdict.json still round 1's" "$(bool cmp -s "$(OUTF "$T")" "$T/r1out.json")"
    rep 0 L-STALE3 "round still 1 after round 2 (fail-open)" "$(bool test "$(rnd "$T")" = 1)"
    rep 0 L-STALE3 "queue unchanged after round 2" "$(bool cmp -s "$S/queue" "$T/q1.txt")"
    echo "textfile=$T/grok_ok.json" > "$T/grok.scn"; echo "textfile=$T/claude_ok.json" > "$T/claude.scn"; run_hook "$T"
    rep 0 L-STALE3 "round 3 prompt: VERIFY ONLY with round 1's finding" "$(bool test "$(has "$(cat "$S/prompt.txt" 2>/dev/null)" "VERIFY ONLY")$(has "$(cat "$S/prompt.txt" 2>/dev/null)" "r1bug")" = 11)"
    rep 0 L-STALE3 "round 3 returns grok's approval" "$(has "$SM" "grok review passed")"; rm -rf "$T"
  fi
  if sel L-VERIFY2; then
    # Round 1: both seats block with distinct findings. Round 2's VERIFY-ONLY prompt
    # must carry BOTH prior findings, not only the first seat's.
    T="$(mkproj)" || exit 2; S="$(STATE "$T")"
    vfile "$T/blk1.json" request_changes '[{"file":"a.php","line":1,"severity":"major","confidence":5,"message":"bug-one","suggestion":null}]'
    vfile "$T/blk2.json" request_changes '[{"file":"a.php","line":2,"severity":"blocker","confidence":5,"message":"bug-two","suggestion":null}]'
    echo "textfile=$T/blk1.json" > "$T/claude.scn"; echo "outfile=$T/blk2.json" > "$T/codex.scn"; run_hook "$T"
    rep 0 L-VERIFY2 "round 1 blocks" "$(bool test "$DEC" = block)"
    echo "textfile=$T/claude_ok.json" > "$T/claude.scn"; echo "outfile=$T/codex_ok.json" > "$T/codex.scn"; run_hook "$T"
    p="$(cat "$S/prompt.txt" 2>/dev/null)"
    rep 0 L-VERIFY2 "round 2 prompt: VERIFY ONLY with bug-one and bug-two" "$(bool test "$(has "$p" "VERIFY ONLY")$(has "$p" bug-one)$(has "$p" bug-two)" = 111)"
    rep 0 L-VERIFY2 "round 2 codex call got that prompt" "$(bool test "$(has "$(cat "$T/codex.stdin.2" 2>/dev/null)" bug-one)$(has "$(cat "$T/codex.stdin.2" 2>/dev/null)" bug-two)" = 11)"
    rep 0 L-VERIFY2 "round 2 releases" "$(has "$SM" "codex review passed")"; rm -rf "$T"
  fi
  if sel L-CODEXSTALE; then
    T="$(mkproj)" || exit 2; mkdir -p "$(STATE "$T")"; printf '{"verdict":"approve","summary":"STALE","findings":[]}' > "$(STATE "$T")/codex.out"
    seed_out "$T" '{"verdict":"approve","summary":"SEED","findings":[]}'; cp "$(OUTF "$T")" "$T/seed.json"
    claudefail "$T"; grok402 "$T"; agy429 "$T"; echo "rc=0" > "$T/codex.scn"; run_hook "$T"
    rep 0 L-CODEXSTALE "fail-open note" "$(has "$SM" "No reviewer could run")"
    rep 0 L-CODEXSTALE "codex never passed (stale codex.out cleared)" "$(bool test "$(has "$SM" "codex review passed")" = 0)"
    rep 0 L-CODEXSTALE "codex reason is 'no answer file' (rc 0 but empty -o)" "$(has "$SM" "no answer file")"
    rep 0 L-CODEXSTALE "verdict.json byte-identical" "$(bool cmp -s "$(OUTF "$T")" "$T/seed.json")"; rm -rf "$T"
  fi

  # ---- L-STATECLR / L-CLRFAIL: the one-time state clear --------------------
  if sel L-STATECLR; then
    # grok and claude are NOT installed here, so neither leg rewrites its own files:
    # only the one-time clear can remove the stale ones.
    T="$(mkproj)" || exit 2; rm -f "$T/bin/grok" "$T/bin/claude"; mkdir -p "$(STATE "$T")"
    printf 'junk' > "$(STATE "$T")/grok.err"; printf 'junk' > "$(STATE "$T")/claude.err"; printf 'junk' > "$(STATE "$T")/claude.out"; run_hook "$T"
    rep 0 L-STATECLR "stale grok.err removed before the loop" "$(bool test ! -e "$(STATE "$T")/grok.err")"
    rep 0 L-STATECLR "stale claude.err removed before the loop" "$(bool test ! -e "$(STATE "$T")/claude.err")"
    rep 0 L-STATECLR "stale claude.out removed before the loop" "$(bool test ! -e "$(STATE "$T")/claude.out")"; rm -rf "$T"
  fi
  if sel L-PRIVATE; then
    # Seat isolation: while codex (seat 2) runs, claude's (seat 1) raw answer must
    # not be ANYWHERE in the repo; the files land in the review-state folder when the
    # hook ends, and the private per-turn folder (TMPDIR, outside the repo) is removed.
    T="$(mkproj)" || exit 2; tp="$(mktemp -d -p "$HARNESS_TMP")" || exit 2; run_hook "$T" TMPDIR="$tp"
    rep 0 L-PRIVATE "codex ran once" "$(bool test "$(ncalls codex "$T/calls")" = 1)"
    rep 0 L-PRIVATE "at codex's start: no claude.out/claude.err anywhere in the repo" "$(bool test -f "$T/codex.peek.1" -a ! -s "$T/codex.peek.1")"
    rep 0 L-PRIVATE "after the hook: claude.out and codex.out in the review-state folder" "$(bool test -s "$(STATE "$T")/claude.out" -a -s "$(STATE "$T")/codex.out")"
    rep 0 L-PRIVATE "the private per-turn folder is removed" "$(bool test -z "$(ls -A "$tp" 2>/dev/null)")"; rm -rf "$T" "$tp"
  fi
  if sel L-CLRFAIL; then
    T="$(mkproj)" || exit 2; mkdir -p "$(STATE "$T")/codex.out"
    seed_out "$T" '{"verdict":"approve","summary":"SEED","findings":[]}' 2>/dev/null || true
    printf '{"verdict":"approve","summary":"SEED","findings":[]}' > "$(STATE "$T")/verdict.json"; cp "$(STATE "$T")/verdict.json" "$T/seed.json"
    run_hook "$T"
    rep 0 L-CLRFAIL "note: cannot clear review state" "$(has "$SM" "cannot clear review state")"
    rep 0 L-CLRFAIL "no reviewer called" "$(bool test "$(( $(ncalls_safe claude "$T/calls") + $(ncalls_safe grok "$T/calls") + $(ncalls_safe agy "$T/calls") + $(ncalls_safe codex "$T/calls") ))" = 0)"
    rep 0 L-CLRFAIL "verdict.json byte-identical" "$(bool cmp -s "$(STATE "$T")/verdict.json" "$T/seed.json")"; rm -rf "$T"
  fi
  if sel L-CODEXRC; then
    T="$(mkproj)" || exit 2; seed_out "$T" '{"verdict":"approve","summary":"SEED","findings":[]}'; cp "$(OUTF "$T")" "$T/seed.json"
    claudefail "$T"; grok402 "$T"; agy429 "$T"; { echo "rc=124"; echo "outfile=$T/codex_ok.json"; } > "$T/codex.scn"; run_hook "$T"
    rep 0 L-CODEXRC "fail-open note" "$(has "$SM" "No reviewer could run")"
    rep 0 L-CODEXRC "verdict.json byte-identical" "$(bool cmp -s "$(OUTF "$T")" "$T/seed.json")"; rm -rf "$T"
  fi
  if sel L-LEGDIRFAIL; then
    # The private per-turn folder cannot be made (TMPDIR is missing): fail OPEN with
    # a note, call no reviewer, leave verdict.json alone.
    T="$(mkproj)" || exit 2; seed_out "$T" '{"verdict":"approve","summary":"SEED","findings":[]}'; cp "$(OUTF "$T")" "$T/seed.json"
    run_hook "$T" TMPDIR="$T/no-such-dir"
    rep 0 L-LEGDIRFAIL "fail-open note" "$(has "$SM" "cannot create its private work folder")"
    rep 0 L-LEGDIRFAIL "no reviewer called" "$(bool test "$(( $(ncalls_safe claude "$T/calls") + $(ncalls_safe grok "$T/calls") + $(ncalls_safe agy "$T/calls") + $(ncalls_safe codex "$T/calls") ))" = 0)"
    rep 0 L-LEGDIRFAIL "verdict.json byte-identical" "$(bool cmp -s "$(OUTF "$T")" "$T/seed.json")"; rm -rf "$T"
  fi
  if sel L-BIGREASON; then
    # Two blocking seats with ~70 KB findings each: the block reason passes one
    # argument's 128 KiB limit (MAX_ARG_STRLEN), so it must reach jq by stdin.
    T="$(mkproj)" || exit 2; big="$(head -c 70000 /dev/zero | tr '\0' x)"
    jq -cn --arg m "A$big" '{verdict:"request_changes",summary:"s1",findings:[{file:"a.php",line:1,severity:"major",confidence:5,message:$m,suggestion:null}]}' > "$T/b1.json"
    jq -cn --arg m "B$big" '{verdict:"request_changes",summary:"s2",findings:[{file:"a.php",line:2,severity:"major",confidence:5,message:$m,suggestion:null}]}' > "$T/b2.json"
    echo "textfile=$T/b1.json" > "$T/claude.scn"; echo "outfile=$T/b2.json" > "$T/codex.scn"; run_hook "$T"
    rep 0 L-BIGREASON "blocks" "$(bool test "$DEC" = block)"
    rep 0 L-BIGREASON "the reason holds both seats' sections" "$(bool test "$(has "$RSN" "🔍 claude review (round 1)")$(has "$RSN" "🔍 codex review (round 1)")" = 11)"
    rep 0 L-BIGREASON "round file is 1" "$(bool test "$(rnd "$T")" = 1)"; rm -rf "$T"
  fi
  if sel L-BIGNOTE; then
    # Two passing seats with ~70 KB summaries each: the release note is too long for
    # one argument, so it too must reach jq by stdin.
    T="$(mkproj)" || exit 2; big="$(head -c 70000 /dev/zero | tr '\0' y)"
    jq -cn --arg s "$big" '{verdict:"approve",summary:$s,findings:[]}' > "$T/a1.json"
    echo "textfile=$T/a1.json" > "$T/claude.scn"; echo "outfile=$T/a1.json" > "$T/codex.scn"; run_hook "$T"
    rep 0 L-BIGNOTE "release note names both seats" "$(bool test "$(has "$SM" "✅ claude review passed")$(has "$SM" "✅ codex review passed")" = 11)"; rm -rf "$T"
  fi
  if sel L-DECFAIL; then
    # Building the block decision fails (a PATH-shadowed jq refuses that one filter):
    # fail OPEN with a note, and do NOT advance the round.
    T="$(mkproj)" || exit 2
    vfile "$T/blk1.json" request_changes '[{"file":"a.php","line":1,"severity":"major","confidence":5,"message":"bug-one","suggestion":null}]'
    echo "textfile=$T/blk1.json" > "$T/claude.scn"
    cat > "$T/bin/jq" <<'JQSTUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *'decision:"block"'*) exit 1 ;; esac; done
exec /usr/bin/jq "$@"
JQSTUB
    chmod +x "$T/bin/jq"; run_hook "$T"
    rep 0 L-DECFAIL "fail-open note" "$(has "$SM" "could not build its decision")"
    rep 0 L-DECFAIL "turn not blocked" "$(bool test -z "$DEC")"
    rep 0 L-DECFAIL "round not advanced" "$(bool test ! -f "$(STATE "$T")/round")"; rm -rf "$T"
  fi
  if sel L-TICK; then
    # A 1.1 s tick in every log line (a date shim) at REVIEW_TIMEOUT=30 with only the
    # two primaries: each share is the 15 s floor, so a primary that re-reads the
    # clock after its log line would skip as "no time left".
    T="$(mkproj)" || exit 2; rm -f "$T/bin/grok" "$T/bin/agy"
    printf '#!/usr/bin/env bash\nsleep 1.1\nexec /usr/bin/date "$@"\n' > "$T/bin/date"; chmod +x "$T/bin/date"
    run_hook "$T" REVIEW_TIMEOUT=30
    rep 0 L-TICK "claude ran and passed" "$(has "$SM" "✅ claude review passed")"
    rep 0 L-TICK "codex ran and passed" "$(has "$SM" "✅ codex review passed")"
    rep 0 L-TICK "no leg skipped as 'no time left'" "$(bool test "$(has "$SM" "no time left")" = 0)"; rm -rf "$T"
  fi
  if sel L-SAVEFAIL; then
    # Saving the verdict fails (target made a directory → mv fails): the hook must
    # fail OPEN, not advance the round or block on findings it never saved.
    T="$(mkproj)" || exit 2
    printf '{"verdict":"request_changes","summary":"x","findings":[{"confidence":5,"file":"a.php","line":1,"message":"m","severity":"blocker","suggestion":null}]}' > "$T/rc.json"
    echo "textfile=$T/rc.json" > "$T/grok.scn"; echo "outfile=$T/rc.json" > "$T/codex.scn"
    mkdir -p "$(STATE "$T")/verdict.json.tmp"        # the temp write target is a dir → jq redirect fails
    # (baseline writes verdict.json directly, so it still blocks → this row is RED on baseline)
    run_hook "$T"
    rep 0 L-SAVEFAIL "fail-open note on save failure" "$(has "$SM" "could not save its verdict")"
    rep 0 L-SAVEFAIL "turn not blocked" "$(bool test -z "$DEC")"
    rep 0 L-SAVEFAIL "round not advanced" "$(bool test ! -f "$(STATE "$T")/round")"; rm -rf "$T"
    # --- mv-failure branch: the jq>tmp write SUCCEEDS but the rename fails (a
    #     PATH-shadowed `mv` that fails only when the dest is verdict.json). Must
    #     also fail OPEN: no block, and the prior saved verdict + round untouched.
    T="$(mkproj)" || exit 2
    printf '{"verdict":"request_changes","summary":"x","findings":[{"confidence":5,"file":"a.php","line":1,"message":"m","severity":"blocker","suggestion":null}]}' > "$T/rc.json"
    echo "textfile=$T/rc.json" > "$T/grok.scn"; echo "outfile=$T/rc.json" > "$T/codex.scn"
    mkdir -p "$(STATE "$T")"
    printf '{"verdict":"approve","summary":"PRIOR","findings":[]}' > "$(STATE "$T")/verdict.json"
    cp "$(STATE "$T")/verdict.json" "$T/prior.json"; echo 1 > "$(STATE "$T")/round"
    cat > "$T/bin/mv" <<'MVSTUB'
#!/usr/bin/env bash
dest="${@: -1}"
case "$dest" in */verdict.json) echo "mv: stub refusing verdict.json" >&2; exit 1 ;; esac
exec /usr/bin/mv "$@"
MVSTUB
    chmod +x "$T/bin/mv"
    run_hook "$T"
    rep 0 L-SAVEFAIL "mv-fail: fail-open note" "$(has "$SM" "could not save its verdict")"
    rep 0 L-SAVEFAIL "mv-fail: turn not blocked" "$(bool test -z "$DEC")"
    rep 0 L-SAVEFAIL "mv-fail: prior verdict.json untouched" "$(bool cmp -s "$(STATE "$T")/verdict.json" "$T/prior.json")"
    rep 0 L-SAVEFAIL "mv-fail: round still 1 (not advanced)" "$(bool test "$(cat "$(STATE "$T")/round" 2>/dev/null)" = 1)"; rm -rf "$T"
  fi
  if sel L-SAVEDIR; then
    # verdict.json IS A DIRECTORY: `jq >tmp` succeeds and `mv -f tmp verdict.json`
    # MOVES tmp INTO the directory and returns rc 0, so without the `&& [ -f "$OUT" ]`
    # guard the save "succeeds" though the verdict file never lands, and the hook
    # blocks on a verdict that is not there. Must fail OPEN. (RED on baseline and on
    # the pre-fix impl: both block.)
    T="$(mkproj)" || exit 2
    printf '{"verdict":"request_changes","summary":"x","findings":[{"confidence":5,"file":"a.php","line":1,"message":"m","severity":"blocker","suggestion":null}]}' > "$T/rc.json"
    echo "textfile=$T/rc.json" > "$T/grok.scn"; echo "outfile=$T/rc.json" > "$T/codex.scn"
    mkdir -p "$(STATE "$T")/verdict.json"        # the SAVE TARGET is a directory
    run_hook "$T"
    rep 0 L-SAVEDIR "dir-target: fail-open note" "$(has "$SM" "could not save its verdict")"
    rep 0 L-SAVEDIR "dir-target: turn not blocked" "$(bool test -z "$DEC")"
    rep 0 L-SAVEDIR "dir-target: round not advanced" "$(bool test ! -f "$(STATE "$T")/round")"; rm -rf "$T"
  fi

  # ---- Time budget rows (these sleep; a few seconds each) ------------------
  if sel L-HANG; then
    T="$(mkproj)" || exit 2; claudefail "$T"; { echo "textfile=$T/grok_ok.json"; echo "sleep=300"; } > "$T/grok.scn"; run_hook "$T" REVIEW_TIMEOUT=60
    rep 0 L-HANG "agy used" "$(bool test "$(nruns agy "$T/calls")" = 1)"
    rep 0 L-HANG "wall < 70" "$(awk -v w="$WALL" 'BEGIN{print (w<70)?1:0}')"
    rep 0 L-HANG "agy --print-timeout >= 10s" "$(awk -v n="$(printtimeout "$T/calls")" 'BEGIN{print (n>=10)?1:0}')"; rm -rf "$T"
  fi
  if sel L-HANGCAT; then
    # codex down -> grok reached. grok's catalogue hangs and is killed at its own
    # limit = min(10, grok_share/3); read grok's actual share from the log so the
    # expected limit tracks the new budget (not a hard-coded number).
    T="$(mkproj)" || exit 2; claudefail "$T"; { echo "textfile=$T/grok_ok.json"; echo "models_sleep=300"; } > "$T/grok.scn"; run_hook "$T" REVIEW_TIMEOUT=60; S="$(STATE "$T")"
    local gshare exp
    gshare="$(logline_ts "$S/review.log" | sed -n 's/.*via grok (share \([0-9]*\)s).*/\1/p' | head -1)"; gshare="${gshare:-0}"
    exp=$(( gshare / 3 )); [ "$exp" -gt 10 ] && exp=10
    # Guards: the catlimit check is meaningless unless grok was actually reached
    # and its catalogue called. Without them a hook that skipped grok straight to
    # agy gives gshare=0 -> exp=0 and catlimit=0, so 0==0 would pass trivially.
    rep 0 L-HANGCAT "grok catalogue called exactly once" "$(bool test "$(ncat grok "$T/calls")" = 1)"
    rep 0 L-HANGCAT "grok got a positive share" "$(awk -v g="$gshare" 'BEGIN{print (g>0)?1:0}')"
    rep 0 L-HANGCAT "grok catalogue limit = min(10, grok_share/3) = $exp (share ${gshare}s)" "$(bool test "$(catlimit "$T/timeouts" grok)" = "$exp")"
    rep 0 L-HANGCAT "no grok run" "$(bool test "$(nruns grok "$T/calls")" = 0)"
    rep 0 L-HANGCAT "agy used, wall < 70" "$([ "$(nruns agy "$T/calls")" = 1 ] && awk -v w="$WALL" 'BEGIN{exit !(w<70)}' && echo 1 || echo 0)"; rm -rf "$T"
  fi
  if sel L-TERM; then
    T="$(mkproj)" || exit 2; claudefail "$T"; { echo "textfile=$T/grok_ok.json"; echo "sleep=300"; echo "ignore_term=1"; } > "$T/grok.scn"; run_hook "$T" REVIEW_TIMEOUT=60
    rep 0 L-TERM "agy used (only -k KILL ends grok)" "$(bool test "$(nruns agy "$T/calls")" = 1)"
    rep 0 L-TERM "wall < 70" "$(awk -v w="$WALL" 'BEGIN{print (w<70)?1:0}')"; rm -rf "$T"
  fi
  if sel L-BUDGET; then
    T="$(mkproj)" || exit 2; { echo "textfile=$T/grok_ok.json"; echo "sleep=300"; } > "$T/grok.scn"
    { echo "textfile=$T/claude_ok.json"; echo "sleep=300"; } > "$T/claude.scn"
    { echo "respfile=$T/agy_ok.json"; echo "sleep=300"; } > "$T/agy.scn"
    { echo "outfile=$T/codex_ok.json"; echo "sleep=300"; } > "$T/codex.scn"; run_hook "$T" REVIEW_TIMEOUT=60
    rep 0 L-BUDGET "wall < 70" "$(awk -v w="$WALL" 'BEGIN{print (w<70)?1:0}')"
    rep 0 L-BUDGET "fail-open names claude, codex, grok, agy" "$(bool test "$(has "$SM" "claude:")$(has "$SM" "codex:")$(has "$SM" "grok:")$(has "$SM" "agy:")" = 1111)"; rm -rf "$T"
  fi
  if sel L-GROUND; then
    T="$(mkproj)" || exit 2; rm -f "$T/bin/agy" "$T/bin/codex" "$T/bin/claude"; install_leg "$T" php; echo "sleep=300" > "$T/php.scn"; run_hook "$T" REVIEW_TIMEOUT=90
    rep 0 L-GROUND "prompt marks (grounding timed out)" "$(has "$(cat "$(STATE "$T")/prompt.txt" 2>/dev/null)" "(grounding timed out)")"
    rep 0 L-GROUND "grok used, wall < 100" "$([ "$(nruns grok "$T/calls")" = 1 ] && awk -v w="$WALL" 'BEGIN{exit !(w<100)}' && echo 1 || echo 0)"; rm -rf "$T"
  fi
  if sel L-FLOOR; then
    T="$(mkproj)" || exit 2; claudefail "$T"; { echo "textfile=$T/grok_ok.json"; echo "models_sleep=300"; echo "models_ignore_term=1"; } > "$T/grok.scn"; run_hook "$T" REVIEW_TIMEOUT=50
    rep 0 L-FLOOR "no timeout limit <= 0" "$(bool test -z "$(limits_pos "$T/timeouts")")"
    rep 0 L-FLOOR "no grok run" "$(bool test "$(nruns grok "$T/calls")" = 0)"
    rep 0 L-FLOOR "agy used, wall < 60" "$([ "$(nruns agy "$T/calls")" = 1 ] && awk -v w="$WALL" 'BEGIN{exit !(w<60)}' && echo 1 || echo 0)"; rm -rf "$T"
  fi
  if sel L-FLOOR2; then
    # claude down (seat 1 needs grok); at T=35 grok's share (wall/untried≈17) floors to
    # its 25s minimum. After a 3s catalogue it still has 25-3-5=17s (>=10) to run,
    # so grok reaches its review and is chosen. Proves the 25s catalogue-leg floor
    # is sized so a model-lookup leg actually reaches its review. If grok's minimum
    # were the codex 15, the floored share would leave 15-3-5=7s<10 and grok would
    # bail "no time left" -> this row kills a "grok minimum = 15" mutant.
    # LIMIT: the leg functions' own `secs<10 -> no time left` guard is DEFENSIVE.
    # In the common case the loop sizes catalogue legs to reach their review (25s
    # floor, clim=min(10,SHARE/3) caps the lookup). But the 5s TERM kill-grace is
    # NOT in that sum, so a catalogue leg that IGNORES TERM can still reach the
    # guard with secs≈7 and bail — the guard is reachable, not dead code, so keep
    # it. This row tests the reachable common side: that the 25s floor lets the
    # leg REACH its review.
    T="$(mkproj)" || exit 2; claudefail "$T"; { echo "textfile=$T/grok_ok.json"; echo "models_sleep=3"; } > "$T/grok.scn"; run_hook "$T" REVIEW_TIMEOUT=35
    rep 0 L-FLOOR2 "grok catalogue was made" "$(bool test "$(ncat grok "$T/calls")" = 1)"
    rep 0 L-FLOOR2 "grok reaches its review (25s floor leaves >=10s after the catalogue)" "$(bool test "$(nruns grok "$T/calls")" = 1)"
    local fshare; fshare="$(logline_ts "$(STATE "$T")/review.log" | sed -n 's/.*via grok (share \([0-9]*\)s).*/\1/p' | head -1)"; fshare="${fshare:-0}"
    rep 0 L-FLOOR2 "grok's allotted share floored to exactly 25s (proves the 25 floor, not 15/20)" "$(bool test "$fshare" = 25)"
    rep 0 L-FLOOR2 "grok chosen" "$(has "$SM" "grok review passed")"; rm -rf "$T"
  fi
  if sel L-DEFAULT; then
    # claude runs first (share 540/4=135, run limit ~share-5), then codex (540/3=180).
    T="$(mkproj)" || exit 2; run_hook "$T"
    rep 0 L-DEFAULT "claude run limit in 115..135 (540/4)" "$(awk -v n="$(runlimit "$T/timeouts" claude)" 'BEGIN{print (n>=115 && n<=135)?1:0}')"
    rep 0 L-DEFAULT "codex run limit in 150..180 (540/3)" "$(awk -v n="$(runlimit "$T/timeouts" codex)" 'BEGIN{print (n>=150 && n<=180)?1:0}')"; rm -rf "$T"
  fi
  if sel L-TIGHT; then
    # Finding-2 regression. base≈42: base/3=14 (<15), base>=15. The preferred leg
    # codex is FLOORED to 15 and RUNS — a tight budget must NOT skip every leg and
    # fail open for "no time". On the reverted fixed-per model (share=base/3=14<15
    # for every leg) all three would be skipped -> this row FAILS there, so it bites.
    T="$(mkproj)" || exit 2; run_hook "$T" REVIEW_TIMEOUT=44
    rep 0 L-TIGHT "claude runs (floored to 15 at a tight budget)" "$(bool test "$(ncalls claude "$T/calls")" -ge 1)"
    rep 0 L-TIGHT "codex runs (floored to 15 at a tight budget)" "$(bool test "$(nruns codex "$T/calls")" -ge 1)"
    rep 0 L-TIGHT "does NOT fail open for lack of time" "$(bool test "$(has "$SM" "No reviewer could run")" = 0)"
    rep 0 L-TIGHT "codex chosen" "$(has "$SM" "codex review passed")"; rm -rf "$T"
  fi
  if sel L-SEATSHARE; then
    # A hung seat-1 leg is bounded to its share and the seat is refilled: claude
    # sleeps (T=60: share 60/4=15, run limit <=15); codex fills seat 2, grok fills
    # seat 1. agy is never called (both seats full).
    T="$(mkproj)" || exit 2; { echo "textfile=$T/claude_ok.json"; echo "sleep=300"; } > "$T/claude.scn"; run_hook "$T" REVIEW_TIMEOUT=60
    rep 0 L-SEATSHARE "claude run limit <= 15" "$(awk -v n="$(runlimit "$T/timeouts" claude)" 'BEGIN{print (n>0 && n<=15)?1:0}')"
    rep 0 L-SEATSHARE "grok fills seat 1, codex seat 2" "$(has "$SM" "✅ grok review passed: ok | ✅ codex review passed: codex-ok")"
    rep 0 L-SEATSHARE "note names claude: exit 124" "$(has "$SM" "claude: exit 124")"
    rep 0 L-SEATSHARE "agy never called" "$(bool test "$(ncalls agy "$T/calls")" = 0)"
    rep 0 L-SEATSHARE "wall < 70" "$(awk -v w="$WALL" 'BEGIN{print (w<70)?1:0}')"; rm -rf "$T"
  fi
  if sel L-SKIPFREE; then
    # Too little time is a skip, not a hang: T=30, claude fails fast, codex burns
    # its share; grok and agy then have < 25s and are skipped as "no time left"
    # without being called -> fail-open, fast.
    T="$(mkproj)" || exit 2; claudefail "$T"; { echo "outfile=$T/codex_ok.json"; echo "sleep=300"; } > "$T/codex.scn"; run_hook "$T" REVIEW_TIMEOUT=30
    rep 0 L-SKIPFREE "grok and agy not called" "$(bool test "$(ncalls grok "$T/calls")/$(ncalls agy "$T/calls")" = 0/0)"
    rep 0 L-SKIPFREE "note: grok and agy 'no time left'" "$(bool test "$(has "$SM" "grok: no time left")$(has "$SM" "agy: no time left")" = 11)"
    rep 0 L-SKIPFREE "fail-open" "$(has "$SM" "No reviewer could run")"
    rep 0 L-SKIPFREE "wall < 40" "$(awk -v w="$WALL" 'BEGIN{print (w<40)?1:0}')"; rm -rf "$T"
  fi

  # ---- L-GUARD: REVIEW_TIMEOUT guard, ground.sh limit = T/3 ----------------
  # Outer gate also opens for a scoped sub-selector like `L-GUARD/30`, so the
  # inner `sel "L-GUARD/$gv"` can actually test it (SEL is a single regex).
  if [ -z "$SEL" ] || [[ "$SEL" == *L-GUARD* ]] || [[ "L-GUARD" =~ $SEL ]]; then
    local gv exp2 gl
    for gv in 5m 08 0 2 29 541 600 ٣٠ 18446744073709551646 30 090; do
      sel "L-GUARD/$gv" || continue
      T="$(mkproj)" || exit 2; rm -f "$T/bin/agy" "$T/bin/codex" "$T/bin/claude"; run_hook "$T" REVIEW_TIMEOUT="$gv"
      exp2="$(guard_exp "$gv")"; gl="$(groundlimit "$T/timeouts")"
      rep 0 "L-GUARD/$gv" "rc 0 and a grok note" "$(bool test "$HOOK_RC" = 0 -a "$(has "$SM" "grok review passed")" = 1)"
      rep 0 "L-GUARD/$gv" "ground.sh limit $gl = $exp2" "$(bool test "$gl" = "$exp2")"
      rep 0 "L-GUARD/$gv" "hook stderr empty" "$(bool test -z "$HOOK_ERR")"; rm -rf "$T"
    done
  fi
  if sel L-OLDTIMEOUT; then
    # The DEPRECATED REVIEW_CODEX_TIMEOUT must map onto the budget. codex runs second
    # (seat 2), so it is checked via codex's own recorded run limit (~budget/3), which
    # is fast and needs no leg to sleep. This cleanly kills a mutant that drops the
    # alias (budget falls back to 540 -> run limit ~180).
    T="$(mkproj)" || exit 2; run_hook "$T" REVIEW_CODEX_TIMEOUT=60
    rep 0 L-OLDTIMEOUT "deprecated REVIEW_CODEX_TIMEOUT honoured (codex run limit 10..30 = 60/3)" "$(awk -v n="$(runlimit "$T/timeouts" codex)" 'BEGIN{print (n>=10 && n<=30)?1:0}')"; rm -rf "$T"
  fi

  # ---- L-ARGV / L-AGYARGV / L-CODEXARGV / L-DISABLE ------------------------
  if sel L-ARGV; then
    T="$(mkproj)" || exit 2; claudefail "$T"; run_hook "$T"; r="$(runargv grok "$T/calls")"; S="$(STATE "$T")"
    rep 0 L-ARGV "--prompt-file is the absolute prompt path" "$(bool test "$(argval "$r" --prompt-file)" = "$S/prompt.txt")"
    rep 0 L-ARGV "--effort high" "$(bool test "$(argval "$r" --effort)" = high)"
    rep 0 L-ARGV "--always-approve" "$(argvhas "$r" --always-approve)"
    rep 0 L-ARGV "--output-format json" "$(bool test "$(argval "$r" --output-format)" = json)"
    rep 0 L-ARGV "--no-subagents" "$(argvhas "$r" --no-subagents)"
    rep 0 L-ARGV "--tools read_file,grep,list_dir" "$(bool test "$(argval "$r" --tools)" = "read_file,grep,list_dir")"
    rep 0 L-ARGV "--deny mcp__*" "$(bool test "$(argval "$r" --deny)" = "mcp__*")"
    rep 0 L-ARGV "--disallowed-tools CallMcpTool" "$(bool test "$(argval "$r" --disallowed-tools)" = CallMcpTool)"
    rep 0 L-ARGV "--cwd is the repo root" "$(bool test "$(argval "$r" --cwd)" = "$T")"
    rep 0 L-ARGV "no --model / -m / -p" "$(bool test "$(argvhas "$r" --model)$(argvhas "$r" -m)$(argvhas "$r" -p)" = 000)"
    local maxlen=0 fld
    while IFS= read -r fld; do [ "${#fld}" -gt "$maxlen" ] && maxlen="${#fld}"; done < <(printf '%s' "$r" | tr '\t' '\n')
    rep 0 L-ARGV "no argv element > 4096 bytes" "$(bool test "$maxlen" -le 4096)"
    rep 0 L-ARGV "grok run stdin empty (prompt is a file)" "$(bool test ! -s "$T/grok.stdin.2")"
    envline="$(sed -n '2p' "$T/grok.env" 2>/dev/null)"
    rep 0 L-ARGV "GROK_CLAUDE_* all 0" "$(case "$envline" in *GROK_CLAUDE_AGENTS_ENABLED=0*GROK_CLAUDE_SKILLS_ENABLED=0*GROK_CLAUDE_MCPS_ENABLED=0*GROK_CLAUDE_HOOKS_ENABLED=0*) echo 1 ;; *) echo 0 ;; esac)"; rm -rf "$T"
  fi
  if sel L-AGYARGV; then
    T="$(mkproj)" || exit 2; claudefail "$T"; grok402 "$T"; run_hook "$T"; r="$(runargv agy "$T/calls")"; S="$(STATE "$T")"
    rep 0 L-AGYARGV "--model gemini-4-argon-medium" "$(bool test "$(argval "$r" --model)" = gemini-4-argon-medium)"
    rep 0 L-AGYARGV "--dangerously-skip-permissions" "$(argvhas "$r" --dangerously-skip-permissions)"
    rep 0 L-AGYARGV "--print-timeout is Ns, N>=10" "$(bool test "$(argval "$r" --print-timeout)" = "$(printtimeout "$T/calls")s" -a "$(printtimeout "$T/calls")" -ge 10)"
    rep 0 L-AGYARGV "--disable-slash-commands" "$(argvhas "$r" --disable-slash-commands)"
    rep 0 L-AGYARGV "--add-dir is the repo root" "$(bool test "$(argval "$r" --add-dir)" = "$T")"
    rep 0 L-AGYARGV "--input-format stream-json" "$(bool test "$(argval "$r" --input-format)" = stream-json)"
    rep 0 L-AGYARGV "--output-format stream-json" "$(bool test "$(argval "$r" --output-format)" = stream-json)"
    rep 0 L-AGYARGV "--sandbox (shell/terminal blocked)" "$(argvhas "$r" --sandbox)"
    rep 0 L-AGYARGV "hook stderr empty (catalogue stderr dropped)" "$(bool test -z "$HOOK_ERR")"
    # stream-json wants ONE NDJSON object per line: the run stdin must be a single
    # line (a pretty-printed object would span several and agy rejects the bare "{").
    rep 0 L-AGYARGV "stdin is one NDJSON line" "$(bool test "$(wc -l < "$T/agy.stdin.2" 2>/dev/null)" = 1)"
    rep 0 L-AGYARGV "stdin: one user event holding the prompt" "$(bool test "$(jq -r 'select(.event=="user")|.message.content' "$T/agy.stdin.2" 2>/dev/null)" = "$(cat "$S/prompt.txt" 2>/dev/null)")"; rm -rf "$T"
  fi
  if sel L-CODEXARGV; then
    # codex is seat 2: claude answers seat 1, then codex runs once.
    # Its answer file is in the private per-turn folder under TMPDIR (outside the repo),
    # whose name has a random 6-character suffix: check the argv around it exactly.
    T="$(mkproj)" || exit 2; tp="$(mktemp -d -p "$HARNESS_TMP")" || exit 2
    run_hook "$T" TMPDIR="$tp"; r="$(runargv codex "$T/calls")"; S="$(STATE "$T")"
    pre="$(printf 'codex\texec\t--skip-git-repo-check\t-s\tread-only\t-C\t%s\t--output-schema\t%s/.claude/review/schema.json\t--output-last-message\t' "$T" "$T")"
    post="$(printf '/codex.out\t--color\tnever')"
    mid=""; [[ "$r" == "$pre"*"$post" ]] && { mid="${r#"$pre"}"; mid="${mid%"$post"}"; }
    argok=0; case "$mid" in "$tp"/review-legs.??????) argok=1 ;; esac
    rep 0 L-CODEXARGV "codex argv is exact (no -m; -o in the private folder under TMPDIR)" "$argok"
    rep 0 L-CODEXARGV "codex stdin is the prompt" "$(bool cmp -s "$T/codex.stdin.1" "$S/prompt.txt")"; rm -rf "$T" "$tp"
  fi
  if sel L-DISABLE; then
    # claude + codex down, grok 402, agy 429, so every leg is actually invoked and
    # its env file exists (two working primaries would otherwise fill both seats).
    T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; grok402 "$T"; agy429 "$T"; run_hook "$T"
    for v in claude grok agy codex; do
      local nl nd
      nl="$(grep -c '' "$T/$v.env" 2>/dev/null || echo 0)"
      nd="$(grep -c 'REVIEW_DISABLE=1' "$T/$v.env" 2>/dev/null || echo 0)"
      rep 0 L-DISABLE "$v env: every call sees REVIEW_DISABLE=1" \
        "$(bool test -s "$T/$v.env" -a "$nd" = "$nl")"
    done; rm -rf "$T"
  fi

  # ---- L-CLAUDEARGV / L-RECURSE / L-CLAUDEFAIL/* (the seat-1 Claude leg) ---
  if sel L-CLAUDEARGV; then
    T="$(mkproj)" || exit 2; run_hook "$T"; r="$(runargv claude "$T/calls")"; S="$(STATE "$T")"
    exp="$(printf 'claude\t-p\t--model\topus\t--output-format\tjson\t--tools\tRead,Grep,Glob\t--permission-mode\tdontAsk\t--no-session-persistence\t--strict-mcp-config\t--settings\t{"disableAllHooks":true}')"
    rep 0 L-CLAUDEARGV "claude argv is exact" "$(bool test "$r" = "$exp")"
    rep 0 L-CLAUDEARGV "claude stdin is the prompt" "$(bool cmp -s "$T/claude.stdin.1" "$S/prompt.txt")"
    rep 0 L-CLAUDEARGV "claude runs in the repo root" "$(bool test "$(cat "$T/claude.cwd.1" 2>/dev/null)" = "$T")"; rm -rf "$T"
  fi
  if sel L-RECURSE; then
    # The nested Claude session's own Stop hook must not start another review.
    T="$(mkproj)" || exit 2; { echo "textfile=$T/claude_ok.json"; echo "nest=1"; } > "$T/claude.scn"; run_hook "$T"
    rep 0 L-RECURSE "nested hook ran and exited 0" "$(bool test "$(cat "$T/nested.rc" 2>/dev/null)" = 0)"
    rep 0 L-RECURSE "claude call saw REVIEW_DISABLE=1" "$(bool test "$(sed -n 1p "$T/claude.env" 2>/dev/null | grep -c 'REVIEW_DISABLE=1 ')" = 1)"
    rep 0 L-RECURSE "the nested run called no reviewer (1 claude + 1 codex in total)" "$(bool test "$(ncalls claude "$T/calls")/$(ncalls codex "$T/calls")/$(ncalls grok "$T/calls")/$(ncalls agy "$T/calls")" = 1/1/0/0)"
    rep 0 L-RECURSE "the nested run printed nothing" "$(bool test ! -s "$T/nested.out")"; rm -rf "$T"
  fi
  local cf
  for cf in rc1 iserror subtype emptyresult sonnet foreign notjson twoobj strfalse objresult nomu emptymu; do
    sel "L-CLAUDEFAIL/$cf" || continue
    T="$(mkproj)" || exit 2
    case "$cf" in
      rc1)         echo "rc=1" > "$T/claude.scn"; exp="claude: exit 1" ;;
      iserror)     { echo "textfile=$T/claude_ok.json"; echo "is_error=true"; } > "$T/claude.scn"; exp="claude: result" ;;
      subtype)     { echo "textfile=$T/claude_ok.json"; echo "subtype=error_max_turns"; } > "$T/claude.scn"; exp="claude: result" ;;
      emptyresult) : > "$T/e.txt"; echo "textfile=$T/e.txt" > "$T/claude.scn"; exp="claude: empty result" ;;
      sonnet)      { echo "textfile=$T/claude_ok.json"; echo "served=claude-sonnet-5-5"; } > "$T/claude.scn"; exp="claude: served" ;;
      foreign)     { echo "textfile=$T/claude_ok.json"; echo "served=claude-opus-5-5,gpt-6"; } > "$T/claude.scn"; exp="claude: served" ;;
      notjson)     printf 'hello\n' > "$T/nj.txt"; { echo "stdout_file=$T/nj.txt"; } > "$T/claude.scn"; exp="claude: not JSON" ;;
      twoobj)      o='{"type":"result","subtype":"success","is_error":false,"result":"x","modelUsage":{"claude-opus-5-5":{}}}'
                   printf '%s\n%s\n' "$o" "$o" > "$T/two.txt"; echo "stdout_file=$T/two.txt" > "$T/claude.scn"; exp="claude: not JSON" ;;
      # envelopes whose ONLY fault is a field type or a missing/empty modelUsage
      strfalse)    jq -cn --rawfile r "$T/claude_ok.json" '{type:"result",subtype:"success",is_error:"false",result:$r,modelUsage:{"claude-opus-5-5":{}}}' > "$T/env.txt"
                   echo "stdout_file=$T/env.txt" > "$T/claude.scn"; exp="claude: result" ;;
      objresult)   jq -cn --rawfile r "$T/claude_ok.json" '{type:"result",subtype:"success",is_error:false,result:($r|fromjson),modelUsage:{"claude-opus-5-5":{}}}' > "$T/env.txt"
                   echo "stdout_file=$T/env.txt" > "$T/claude.scn"; exp="claude: result" ;;
      nomu)        jq -cn --rawfile r "$T/claude_ok.json" '{type:"result",subtype:"success",is_error:false,result:$r}' > "$T/env.txt"
                   echo "stdout_file=$T/env.txt" > "$T/claude.scn"; exp="claude: served" ;;
      emptymu)     jq -cn --rawfile r "$T/claude_ok.json" '{type:"result",subtype:"success",is_error:false,result:$r,modelUsage:{}}' > "$T/env.txt"
                   echo "stdout_file=$T/env.txt" > "$T/claude.scn"; exp="claude: served" ;;
    esac
    run_hook "$T"
    rep 0 "L-CLAUDEFAIL/$cf" "claude rejected, grok fills seat 1" "$(has "$SM" "✅ grok review passed: ok | ✅ codex review passed: codex-ok")"
    rep 0 "L-CLAUDEFAIL/$cf" "note reason: $exp" "$(has "$SM" "$exp")"
    rep 0 "L-CLAUDEFAIL/$cf" "claude-ok never accepted" "$(bool test "$(has "$SM" "claude review passed")" = 0)"; rm -rf "$T"
  done

  # ---- L-COMBINE/* / L-ONESEAT / L-FILLORDER: the two-seat verdict --------
  local cb
  for cb in seat1 seat2 both minor cross; do
    sel "L-COMBINE/$cb" || continue
    T="$(mkproj)" || exit 2
    vfile "$T/blk1.json" request_changes '[{"file":"a.php","line":1,"severity":"major","confidence":5,"message":"bug-one","suggestion":null}]'
    vfile "$T/blk2.json" request_changes '[{"file":"a.php","line":2,"severity":"blocker","confidence":5,"message":"bug-two","suggestion":null}]'
    case "$cb" in
      seat1) echo "textfile=$T/blk1.json" > "$T/claude.scn" ;;
      seat2) echo "outfile=$T/blk2.json" > "$T/codex.scn" ;;
      both)  echo "textfile=$T/blk1.json" > "$T/claude.scn"; echo "outfile=$T/blk2.json" > "$T/codex.scn" ;;
      minor) vfile "$T/mn.json" request_changes "$F_MINOR5"; echo "textfile=$T/mn.json" > "$T/claude.scn" ;;
      # seat 1 says request_changes but has only a minor; seat 2 approves with a major:
      # neither seat has BOTH, so the turn is released (a seat is ranked by its own findings)
      cross) vfile "$T/mn.json" request_changes "$F_MINOR5"; echo "textfile=$T/mn.json" > "$T/claude.scn"
             vfile "$T/apmaj.json" approve '[{"file":"a.php","line":3,"severity":"major","confidence":5,"message":"bug-three","suggestion":null}]'
             echo "outfile=$T/apmaj.json" > "$T/codex.scn" ;;
    esac
    run_hook "$T"
    case "$cb" in
      seat1) rep 0 L-COMBINE/seat1 "blocks on seat 1 alone" "$(bool test "$DEC" = block)"
             rep 0 L-COMBINE/seat1 "verdict.json: request_changes, seat 1's one finding" "$(bool test "$(jq -c '[.verdict,(.findings|length)]' "$(OUTF "$T")" 2>/dev/null)" = '["request_changes",1]')"
             rep 0 L-COMBINE/seat1 "reason names claude, not codex" "$(bool test "$(has "$RSN" "🔍 claude review (round 1) requested changes")$(has "$RSN" "🔍 codex review")" = 10)" ;;
      seat2) rep 0 L-COMBINE/seat2 "blocks on seat 2 alone" "$(bool test "$DEC" = block)"
             rep 0 L-COMBINE/seat2 "reason names codex, not claude" "$(bool test "$(has "$RSN" "🔍 codex review (round 1) requested changes")$(has "$RSN" "🔍 claude review")" = 10)" ;;
      both)  rep 0 L-COMBINE/both "blocks" "$(bool test "$DEC" = block)"
             rep 0 L-COMBINE/both "one section per seat, claude first" "$(awk -v r="$RSN" 'BEGIN{a=index(r,"🔍 claude review (round 1)"); b=index(r,"🔍 codex review (round 1)"); print (a>0 && b>a)?1:0}')"
             rep 0 L-COMBINE/both "both findings in the reason" "$(bool test "$(has "$RSN" bug-one)$(has "$RSN" bug-two)" = 11)"
             rep 0 L-COMBINE/both "one footer" "$(bool test "$(printf '%s' "$RSN" | grep -c 'then finish')" = 1)"
             rep 0 L-COMBINE/both "verdict.json holds both findings" "$(bool test "$(jq -c '[.verdict,(.findings|length)]' "$(OUTF "$T")" 2>/dev/null)" = '["request_changes",2]')"
             rep 0 L-COMBINE/both "verdict.json findings: exactly bug-one then bug-two" "$(bool test "$(jq -c '[.findings[].message]' "$(OUTF "$T")" 2>/dev/null)" = '["bug-one","bug-two"]')" ;;
      cross) rep 0 L-COMBINE/cross "released: no seat has request_changes AND a qualifying finding" "$(bool test -z "$DEC")"
             rep 0 L-COMBINE/cross "round not advanced" "$(bool test ! -f "$(STATE "$T")/round")" ;;
      minor) rep 0 L-COMBINE/minor "minor only -> released" "$(bool test -z "$DEC")"
             rep 0 L-COMBINE/minor "note: claude passed with 1 minor note, codex passed" "$(bool test "$(has "$SM" "✅ claude review passed (with 1 minor note(s))")$(has "$SM" "✅ codex review passed: codex-ok")" = 11)" ;;
    esac
    rm -rf "$T"
  done
  if sel L-ONESEAT; then
    # Only one seat can be filled: claude down, grok 402, agy 429 -> codex alone.
    T="$(mkproj)" || exit 2; claudefail "$T"; grok402 "$T"; agy429 "$T"; run_hook "$T"
    rep 0 L-ONESEAT "released on codex alone" "$(bool test -z "$DEC" -a "$(has "$SM" "✅ codex review passed: codex-ok")" = 1)"
    rep 0 L-ONESEAT "warns only one reviewer ran" "$(has "$SM" "⚠️ only one reviewer ran")"
    rep 0 L-ONESEAT "verdict.json summary is codex's alone" "$(bool test "$(jq -r .summary "$(OUTF "$T")" 2>/dev/null)" = "codex: codex-ok")"; rm -rf "$T"
  fi
  if sel L-FILLORDER; then
    # Both primaries down: grok fills seat 1, agy seat 2 (the first empty seat each time).
    T="$(mkproj)" || exit 2; claudefail "$T"; codexfail "$T"; run_hook "$T"
    rep 0 L-FILLORDER "calls: claude, codex, grok models, grok, agy models, agy" "$(bool test "$(callseq "$T/calls")" = "claude, codex, grok models, grok, agy models, agy")"
    rep 0 L-FILLORDER "note: grok then agy" "$(has "$SM" "✅ grok review passed: ok | ✅ agy review passed: agy-ok")"; rm -rf "$T"
  fi

  # ---- L-FOOTER / L-CONF / L-BLOCK / L-MINOR / L-FALLNOTE / L-MAXROUNDS -----
  if sel L-FOOTER; then
    T="$(mkproj)" || exit 2; run_hook "$T"; S="$(STATE "$T")"
    rep 0 L-FOOTER "prompt holds the schema" "$(bool test "$(has "$(cat "$S/prompt.txt" 2>/dev/null)" '"request_changes"')$(has "$(cat "$S/prompt.txt" 2>/dev/null)" 'additionalProperties')" = 11)"
    rep 0 L-FOOTER "prompt ends with the reply rule" "$(bool test "$(awk 'NF{l=$0} END{print l}' "$S/prompt.txt" 2>/dev/null)" = "Reply with exactly one JSON object that matches this schema.")"; rm -rf "$T"
  fi
  if sel 'L-CONF/4'; then
    T="$(mkproj)" || exit 2; codexfail "$T"; vfile "$T/c4.json" request_changes '[{"file":"a.php","line":1,"severity":"major","confidence":4,"message":"x","suggestion":null}]'
    echo "textfile=$T/c4.json" > "$T/grok.scn"; run_hook "$T"
    rep 0 L-CONF/4 "major at confidence 4 blocks" "$(bool test "$DEC" = block)"; rm -rf "$T"
  fi
  if sel 'L-CONF/3'; then
    T="$(mkproj)" || exit 2; codexfail "$T"; vfile "$T/c3.json" request_changes '[{"file":"a.php","line":1,"severity":"major","confidence":3,"message":"x","suggestion":null}]'
    echo "textfile=$T/c3.json" > "$T/grok.scn"; run_hook "$T"
    rep 0 L-CONF/3 "major at confidence 3 released" "$(bool test -z "$DEC" -a "$(has "$SM" "grok review passed")" = 1)"; rm -rf "$T"
  fi
  if sel L-BLOCK; then
    T="$(mkproj)" || exit 2; codexfail "$T"; vfile "$T/b.json" request_changes "$F_MAJOR5"; echo "textfile=$T/b.json" > "$T/grok.scn"; run_hook "$T"
    rep 0 L-BLOCK "decision is block" "$(bool test "$DEC" = block)"
    rep 0 L-BLOCK "reason names grok round 1" "$(has "$RSN" "🔍 grok review (round 1) requested changes")"
    rep 0 L-BLOCK "round file is 1" "$(bool test "$(rnd "$T")" = 1)"; rm -rf "$T"
  fi
  if sel L-MINOR; then
    # codexfail makes grok the chosen leg; its note then carries codex's skip clause
    # BETWEEN "passed" and "(with ...)", so assert released + both parts present.
    T="$(mkproj)" || exit 2; codexfail "$T"; vfile "$T/m.json" request_changes "$F_MINOR5"; echo "textfile=$T/m.json" > "$T/grok.scn"; run_hook "$T"
    rep 0 L-MINOR "released with the minor note" "$(bool test -z "$DEC" -a "$(has "$SM" "grok review passed")" = 1 -a "$(has "$SM" "with 1 minor note(s)")" = 1)"; rm -rf "$T"
  fi
  if sel L-FALLNOTE; then
    # codex down + grok 402 -> agy is chosen and its note names the skipped legs.
    T="$(mkproj)" || exit 2; codexfail "$T"; grok402 "$T"; run_hook "$T"
    rep 0 L-FALLNOTE "agy note names the skipped legs" "$(bool test "$(has "$SM" "agy review passed")$(has "$SM" "codex:")$(has "$SM" "grok:")" = 111)"; rm -rf "$T"
  fi
  if sel L-MAXROUNDS; then
    T="$(mkproj)" || exit 2; mkdir -p "$(STATE "$T")"; echo 4 > "$(STATE "$T")/round"; run_hook "$T"
    rep 0 L-MAXROUNDS "did not converge, no 'Codex'" "$(bool test "$(has "$SM" "did not converge")" = 1 -a "$(has "$SM" "Codex")" = 0)"; rm -rf "$T"
  fi

  # ---- L-SETTINGS / L-DOCS: the tracked worktree files ---------------------
  if sel L-SETTINGS; then
    S="$REVIEW_SRC/../settings.json"
    rep 0 L-SETTINGS "Stop hook timeout 600" "$(bool test "$(jq '.hooks.Stop[0].hooks[0].timeout' "$S" 2>/dev/null)" = 600)"
    rep 0 L-SETTINGS "statusMessage updated" "$(bool test "$(jq -r '.hooks.Stop[0].hooks[0].statusMessage' "$S" 2>/dev/null)" = "Running second-opinion review…")"
    # settings.json invokes the Stop/PostToolUse hooks as BARE PATHS (not via
    # `bash`), so the SOURCE scripts must keep their exec bit or the deployed hook
    # fails rc 126 Permission denied and the whole loop never runs. Assert on the
    # real source ($REVIEW_SRC) — mkproj copies without -p, so a $T copy's mode is
    # meaningless. RED when stop-gate.sh is 644.
    rep 0 L-SETTINGS "stop-gate.sh (bare-path Stop hook) is executable" "$(bool test -x "$REVIEW_SRC/stop-gate.sh")"
    rep 0 L-SETTINGS "sibling bare-path hooks executable" "$(bool test -x "$REVIEW_SRC/guard-bash.sh" -a -x "$REVIEW_SRC/queue.sh")"
    # A fresh checkout takes the working-tree mode from the COMMITTED index, which
    # is where the round-2 blocker shipped. Assert the committed mode is 100755 for
    # the Stop entry point and its bare-path siblings. A missing/uncommitted file
    # yields an empty mode → FAIL (also catches a Stop command pointed at nothing).
    rep 0 L-SETTINGS "stop-gate.sh committed mode 100755 (deploy guard)" "$(bool test "$(cd "$REVIEW_SRC" && git ls-files -s stop-gate.sh 2>/dev/null | cut -c1-6)" = 100755)"
    rep 0 L-SETTINGS "sibling hooks committed mode 100755" "$(bool test "$(cd "$REVIEW_SRC" && git ls-files -s guard-bash.sh queue.sh ground.sh 2>/dev/null | cut -c1-6 | sort -u | tr -d '\n')" = 100755)"
  fi
  if sel L-DOCS; then
    local rootreadme="$REVIEW_SRC/../../README.md" revreadme="$REVIEW_SRC/README.md" cfg="$REVIEW_SRC/config.sh" hook="$REVIEW_SRC/stop-gate.sh"
    # The docs must describe the NEW attempt order verbatim, the REVIEW_TIMEOUT
    # knob and its 540 default — and must NOT carry the old order string.
    docok() { grep -qF "claude → codex → grok → agy" "$1" 2>/dev/null \
              && grep -q "REVIEW_TIMEOUT" "$1" 2>/dev/null && grep -q "540" "$1" 2>/dev/null \
              && ! grep -qF "codex → grok → codex → agy → codex" "$1" 2>/dev/null \
              && ! grep -qF "grok → agy → codex" "$1" 2>/dev/null; }
    rep 0 L-DOCS "root README.md: new order, REVIEW_TIMEOUT, 540" "$(bool docok "$rootreadme")"
    rep 0 L-DOCS "review README.md: new order, REVIEW_TIMEOUT, 540" "$(bool docok "$revreadme")"
    rep 0 L-DOCS "config.sh: new order, REVIEW_TIMEOUT, 540" "$(bool docok "$cfg")"
    # The block rule (both halves), the seat-1 fallback (grok, then agy) and the
    # managed-hooks caveat, as written in both READMEs.
    docrule() { grep -qF 'returns `request_changes` with a **major/blocker** finding at confidence ≥ `REVIEW_MIN_CONFIDENCE`' "$1" 2>/dev/null \
                && grep -qF 'grok, then agy, fills seat 1' "$1" 2>/dev/null \
                && ! grep -qF 'grok fills seat 1' "$1" 2>/dev/null \
                && grep -qF 'managed settings' "$1" 2>/dev/null; }
    rep 0 L-DOCS "root README.md: block rule, seat-1 fallback, managed hooks" "$(bool docrule "$rootreadme")"
    rep 0 L-DOCS "review README.md: block rule, seat-1 fallback, managed hooks" "$(bool docrule "$revreadme")"
    rep 0 L-DOCS "no REVIEW_LEGS anywhere" "$(bool test "$(grep -l REVIEW_LEGS "$rootreadme" "$revreadme" "$cfg" "$hook" 2>/dev/null | wc -l)" = 0)"
  fi
}
leg_rows

printf 'self_fail=%s t_fail=%s\n' "$SELF_FAIL" "$T_FAIL"
# A non-empty selector that matched no rows ran nothing — exit non-zero so a
# mistyped scoped/mutation selector cannot look green (mutation reads the exit).
if [ -n "$SEL" ] && [ "$SEL_HITS" -eq 0 ]; then
    printf 'ERROR: selector "%s" matched no rows (nothing selector-gated ran)\n' "$SEL" >&2
    exit 2
fi
[ "$FAIL" -eq 0 ]
