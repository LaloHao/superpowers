#!/usr/bin/env bash
# Regression check: brainstorming times its phase (excluding time spent
# waiting on the human) and offers to publish it to Jira at the end.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$REPO_ROOT/skills/brainstorming/SKILL.md"

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

echo "=== brainstorming worklog timing test ==="
echo ""

assert_contains "Start time tracking and explore project context" "Checklist item 1 starts time tracking, not a loose paragraph"
assert_contains "time-log start" "Starts the phase timer"
assert_contains "already mentioned a Jira issue key" "Captures an already-given Jira key immediately after start"
assert_contains "wasn't able to track time automatically" "Tells the human when automatic tracking failed"
assert_contains "log an approximate duration manually" "Offers a manual-duration fallback"
assert_contains "time-log pause" "Pauses the timer around user waits"
assert_contains "time-log resume" "Resumes the timer after user responds"
assert_contains "time-log end" "Ends the phase timer"
assert_contains "set-jira" "References set-jira for the one-time issue ask"
assert_contains "JIRA: unknown" "Checks for the unknown-jira sentinel before asking"
assert_contains "addWorklogToJiraIssue" "References the Jira worklog MCP tool"

echo ""
if [[ "$failures" -ne 0 ]]; then
    echo "FAILED: $failures assertion(s)."
    exit 1
fi
echo "PASS"
