#!/usr/bin/env bash
# Regression check: subagent-driven-development times each task and the
# final review (excluding time spent waiting on the human) and offers to
# publish each to Jira.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$REPO_ROOT/skills/subagent-driven-development/SKILL.md"

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

echo "=== subagent-driven-development worklog timing test ==="
echo ""

assert_contains "time-log start" "Starts a phase timer per task"
assert_contains "time-log pause" "Pauses around real human-wait points"
assert_contains "time-log resume" "Resumes after the human responds"
assert_contains "time-log end" "Ends the phase timer"
assert_contains "final-review" "Times the final-review phase separately"
assert_contains "set-jira" "References set-jira for the one-time issue ask"
assert_contains "addWorklogToJiraIssue" "References the Jira worklog MCP tool"

echo ""
if [[ "$failures" -ne 0 ]]; then
    echo "FAILED: $failures assertion(s)."
    exit 1
fi
echo "PASS"
