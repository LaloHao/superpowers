#!/usr/bin/env bash
# Regression check: writing-plans requires a Depends-on field per task and
# fans out File Structure exploration to parallel subagents when there are
# 2+ independent things to investigate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$REPO_ROOT/skills/writing-plans/SKILL.md"

failures=0

assert_contains() {
    local pattern="$1"
    local label="$2"

    if grep -Fq "$pattern" "$SKILL"; then
        echo "  [PASS] $label"
    else
        echo "  [FAIL] $label"
        echo "    Expected to find: $pattern"
        echo "    In file: $SKILL"
        failures=$((failures + 1))
    fi
}

echo "=== writing-plans parallel exploration test ==="
echo ""

assert_contains "**Depends on:**" "Task Structure includes a Depends on field"
assert_contains "Depends on" "Depends-on field mentioned outside just the template"
assert_contains "2+ items" "Mechanical rule: 2+ independent items triggers parallel dispatch"
assert_contains "collapses to 1 item" "Mechanical rule: 1 item means no subagent dispatch"

echo ""
if [[ "$failures" -ne 0 ]]; then
    echo "FAILED: $failures assertion(s)."
    exit 1
fi
echo "PASS"
