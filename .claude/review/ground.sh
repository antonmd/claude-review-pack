#!/usr/bin/env bash
# Run grounding linters on the given files (passed as args) and print a
# markdown report to stdout. Every tool degrades gracefully if missing.
set -uo pipefail

REVIEW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$REVIEW_DIR/lib.sh"

PHPCS="$TOOLS_DIR/vendor/bin/phpcs"
STYLELINT="$TOOLS_DIR/node_modules/.bin/stylelint"
PHPCS_RULESET="$REVIEW_DIR/phpcs.xml"
STYLELINT_CFG="$TOOLS_DIR/.stylelintrc.json"

php_files=()
style_files=()
sh_files=()
json_files=()
nginx_files=()
compose_files=()
for f in "$@"; do
    case "$f" in
        *.php) php_files+=("$f") ;;
        *.scss|*.css) style_files+=("$f") ;;
        *.sh|*.bash) sh_files+=("$f") ;;
        *.json) json_files+=("$f") ;;
        *.conf|*.nginx) nginx_files+=("$f") ;;
    esac
    # compose files match by name, not extension
    case "$(basename "$f")" in
        docker-compose.yml|docker-compose.yaml|compose.yml|compose.yaml) compose_files+=("$f") ;;
    esac
done

echo "## Tool grounding"
echo

# ---- php -l (syntax) -------------------------------------------------------
if [ "${#php_files[@]}" -gt 0 ] && command -v php >/dev/null 2>&1; then
    echo "### php -l (syntax)"
    syntax_clean=1
    for f in "${php_files[@]}"; do
        out="$(php -l "$f" 2>&1)"
        if ! printf '%s' "$out" | grep -q "No syntax errors"; then
            echo "- \`$f\`: $out"
            syntax_clean=0
        fi
    done
    [ "$syntax_clean" -eq 1 ] && echo "All changed PHP files pass php -l."
    echo
fi

# ---- PHPCS (WordPress, security-focused) -----------------------------------
if [ "${#php_files[@]}" -gt 0 ] && [ -x "$PHPCS" ]; then
    echo "### PHP_CodeSniffer (WordPress standard)"
    report="$("$PHPCS" --standard="$PHPCS_RULESET" --report=json --runtime-set ignore_warnings_on_exit 1 "${php_files[@]}" 2>/dev/null)"
    if [ -n "$report" ] && command -v jq >/dev/null 2>&1; then
        flat="$(printf '%s' "$report" | jq -r '
            .files | to_entries[] as $f
            | $f.value.messages[]
            | "- \($f.key | sub(".*/";"")):\(.line) [\(.type)] \(.source) — \(.message)"
        ' 2>/dev/null | head -40)"
        if [ -n "$flat" ]; then
            printf '%s\n' "$flat"
            total="$(printf '%s' "$report" | jq -r '[.files[].messages[]] | length' 2>/dev/null)"
            [ "${total:-0}" -gt 40 ] && echo "- … and $((total - 40)) more"
        else
            echo "No PHPCS findings."
        fi
    else
        echo "(PHPCS produced no parseable report.)"
    fi
    echo
fi

# ---- stylelint (SCSS/CSS) --------------------------------------------------
if [ "${#style_files[@]}" -gt 0 ] && [ -x "$STYLELINT" ]; then
    echo "### stylelint (SCSS/CSS)"
    out="$("$STYLELINT" --config "$STYLELINT_CFG" --formatter compact "${style_files[@]}" 2>&1 | head -40)"
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | sed 's#.*/##'
    else
        echo "No stylelint findings."
    fi
    echo
fi

# ---- ShellCheck (.sh / .bash) ----------------------------------------------
if [ "${#sh_files[@]}" -gt 0 ] && command -v shellcheck >/dev/null 2>&1; then
    echo "### ShellCheck (shell)"
    out="$(shellcheck -f gcc "${sh_files[@]}" 2>&1 | head -40)"
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | sed 's#.*/##'
    else
        echo "No ShellCheck findings."
    fi
    echo
fi

# ---- jq parse (.json syntax) -----------------------------------------------
if [ "${#json_files[@]}" -gt 0 ] && command -v jq >/dev/null 2>&1; then
    echo "### jq (JSON syntax)"
    json_clean=1
    for f in "${json_files[@]}"; do
        err="$(jq empty "$f" 2>&1)" || { echo "- \`$(basename "$f")\`: $err"; json_clean=0; }
    done
    [ "$json_clean" -eq 1 ] && echo "All changed JSON files parse clean."
    echo
fi

# ---- nginx -t (nginx conf, via proxy-nginx container) ----------------------
if [ "${#nginx_files[@]}" -gt 0 ] && command -v docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^proxy-nginx$'; then
        echo "### nginx -t (config test)"
        out="$(docker exec proxy-nginx nginx -t 2>&1 | head -20)"
        printf '%s\n' "$out"
        echo
    fi
fi

# ---- docker compose config (compose file validity) -------------------------
if [ "${#compose_files[@]}" -gt 0 ] && command -v docker >/dev/null 2>&1; then
    echo "### docker compose config (validity)"
    for f in "${compose_files[@]}"; do
        dir="$(dirname "$f")"
        if err="$(cd "$dir" && docker compose config -q 2>&1)"; then
            echo "- \`$(basename "$f")\`: valid"
        else
            printf -- '- `%s`: %s\n' "$(basename "$f")" "$(printf '%s' "$err" | head -5)"
        fi
    done
    echo
fi

exit 0
