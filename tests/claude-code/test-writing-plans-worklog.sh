#!/usr/bin/env bash
# Regression check: writing-plans resolves time tracking once per topic
# via a single upfront question (before any time-log calls), then
# behaves automatically for the rest of the phase. Also regression-tests
# a prior ordering bug: pause must happen before the execution-choice
# offer (a wait point), and end must happen after — never end-then-pause
# on an already-closed phase.

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

echo "=== writing-plans worklog timing test ==="
echo ""

assert_contains "time-log status" "Checks resolved tracking state before doing anything else"
assert_contains "Do you want time tracked" "Asks the single upfront tracking question"
assert_contains "set-jira <topic> disabled" "Persists a decline as disabled"
assert_contains "What Jira ticket does this correspond to" "Asks for the ticket only after tracking is wanted"
assert_contains 'zero `time-log` calls' "Documents zero instrumentation when disabled"
assert_contains "no confirmation prompt" "Auto-publishes without asking each phase"
assert_contains "wasn't able to track time automatically" "Tells the human when automatic tracking failed"
assert_contains "log an approximate duration manually" "Offers a manual-duration fallback"
assert_contains "time-log pause" "Pauses around the execution-choice offer"
assert_contains "time-log resume" "Resumes after the user answers"
assert_contains "time-log end" "Ends the phase timer"
assert_contains "addWorklogToJiraIssue" "References the Jira worklog MCP tool"
assert_not_contains "already mentioned a Jira issue key" "Old early-capture wording is gone"
assert_not_contains "Is this Jira-tracked work?" "Old per-phase-end ask is gone"

pause_line=$(grep -n 'run `scripts/time-log pause <topic>` now' "$SKILL" | head -1 | cut -d: -f1)
end_line=$(grep -n 'run `scripts/time-log end <topic>`. If it fails' "$SKILL" | head -1 | cut -d: -f1)
if [[ -n "$pause_line" && -n "$end_line" && "$pause_line" -lt "$end_line" ]]; then
    echo "  [PASS] pause happens before the offer, end happens after (fixes prior ordering bug)"
else
    echo "  [FAIL] pause happens before the offer, end happens after (fixes prior ordering bug)"
    echo "    pause_line=$pause_line end_line=$end_line"
    failures=$((failures + 1))
fi

echo ""
if [[ "$failures" -ne 0 ]]; then
    echo "FAILED: $failures assertion(s)."
    exit 1
fi
echo "PASS"
