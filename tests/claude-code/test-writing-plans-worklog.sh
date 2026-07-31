#!/usr/bin/env bash
# Regression check: writing-plans times its phase (excluding the one real
# user wait point) and offers to publish it to Jira before the execution
# handoff.

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

echo "=== writing-plans worklog timing test ==="
echo ""

assert_contains "time-log start" "Starts the phase timer"
assert_contains "time-log pause" "Pauses around the execution-choice offer"
assert_contains "time-log resume" "Resumes after the user answers"
assert_contains "time-log end" "Ends the phase timer"
assert_contains "set-jira" "References set-jira for the one-time issue ask"
assert_contains "addWorklogToJiraIssue" "References the Jira worklog MCP tool"

echo ""
if [[ "$failures" -ne 0 ]]; then
    echo "FAILED: $failures assertion(s)."
    exit 1
fi
echo "PASS"
