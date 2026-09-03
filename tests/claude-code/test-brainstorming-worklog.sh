#!/usr/bin/env bash
# Regression check: brainstorming resolves time tracking once per topic
# via a single upfront question (before any time-log calls), then
# behaves automatically for the rest of the phase: no tracking, tracked
# only, or tracked with automatic Jira publish.

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

assert_not_contains() {
    local pattern="$1"
    local label="$2"

    if grep -Fq "$pattern" "$SKILL"; then
        echo "  [FAIL] $label"
        echo "    Did not expect to find: $pattern"
        echo "    In file: $SKILL"
        failures=$((failures + 1))
    else
        echo "  [PASS] $label"
    fi
}

echo "=== brainstorming worklog timing test ==="
echo ""

assert_contains "time-log status" "Checks resolved tracking state before doing anything else"
assert_contains "Do you want time tracked" "Asks the single upfront tracking question"
assert_contains "set-jira <topic> disabled" "Persists a decline as disabled"
assert_contains "What Jira ticket does this correspond to" "Asks for the ticket only after tracking is wanted"
assert_contains 'zero `time-log` calls' "Documents zero instrumentation when disabled"
assert_contains "no confirmation prompt" "Auto-publishes without asking each phase"
assert_contains "JIRA: unknown" "Checks for the unknown-jira sentinel before asking"
assert_contains "wasn't able to track time automatically" "Tells the human when automatic tracking failed"
assert_contains "log an approximate duration manually" "Offers a manual-duration fallback"
assert_contains "time-log pause" "Pauses the timer around user waits"
assert_contains "time-log resume" "Resumes the timer after user responds"
assert_contains "time-log end" "Ends the phase timer"
assert_contains "addWorklogToJiraIssue" "References the Jira worklog MCP tool"
assert_not_contains "already mentioned a Jira issue key" "Old early-capture wording is gone"
assert_not_contains "Is this Jira-tracked work?" "Old per-phase-end ask is gone"

echo ""
if [[ "$failures" -ne 0 ]]; then
    echo "FAILED: $failures assertion(s)."
    exit 1
fi
echo "PASS"
