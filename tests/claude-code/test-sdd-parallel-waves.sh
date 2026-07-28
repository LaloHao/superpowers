#!/usr/bin/env bash
# Regression check: subagent-driven-development dispatches independent
# tasks in parallel waves using per-task worktrees, instead of forbidding
# parallel implementers outright.

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

echo "=== subagent-driven-development wave dispatch test ==="
echo ""

assert_not_contains "Never dispatch multiple implementation subagents in parallel" "Old blanket parallel ban removed"
assert_contains "task-worktree" "References the task-worktree script"
assert_contains "Depends on" "References the Depends-on field"
assert_contains "wave" "Describes wave-based dispatch"
assert_contains "4" "States the concurrency cap"
assert_contains "Workflow" "Documents the Workflow-tool fast path"

echo ""
if [[ "$failures" -ne 0 ]]; then
    echo "FAILED: $failures assertion(s)."
    exit 1
fi
echo "PASS"
