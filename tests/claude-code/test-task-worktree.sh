#!/usr/bin/env bash
# Tests for scripts/task-worktree: per-task worktree isolation for
# subagent-driven-development's parallel wave dispatch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SDD_SCRIPTS="$REPO_ROOT/skills/subagent-driven-development/scripts"

FAILURES=0
TEST_ROOT=""

pass() { echo "  [PASS] $1"; }
fail() {
    echo "  [FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

cleanup() {
    if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
        rm -rf "$TEST_ROOT"
    fi
}

main() {
    echo "=== Test: task-worktree ==="

    TEST_ROOT="$(mktemp -d)"
    trap cleanup EXIT

    git init -q -b main "$TEST_ROOT/repo"
    local repo
    repo="$(cd "$TEST_ROOT/repo" && git rev-parse --show-toplevel)"

    local git_id=(-c user.email=t@example.com -c user.name=t -c commit.gpgsign=false)
    cat > "$repo/plan-a.md" <<'PLAN'
# Plan A

## Task 1: First thing

Do the first thing.
PLAN
    ( cd "$repo" && git add plan-a.md && git "${git_id[@]}" commit -qm c1 )
    local head1
    head1="$(cd "$repo" && git rev-parse HEAD)"
    printf 'y\n' > "$repo/f" && ( cd "$repo" && git add f && git "${git_id[@]}" commit -qm c2 )

    # --- usage validation ---
    local rc=0
    (cd "$repo" && "$SDD_SCRIPTS/task-worktree" >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 2 ]] && pass "no args errors with exit 2" || { fail "no args errors with exit 2"; echo "    exit: $rc"; }

    rc=0
    (cd "$repo" && "$SDD_SCRIPTS/task-worktree" bogus plan-a.md 1 >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 2 ]] && pass "unknown subcommand errors with exit 2" || { fail "unknown subcommand errors with exit 2"; echo "    exit: $rc"; }

    rc=0
    (cd "$repo" && "$SDD_SCRIPTS/task-worktree" add no-such-plan.md 1 >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 2 ]] && pass "add with missing plan file errors with exit 2" || { fail "add with missing plan file errors with exit 2"; echo "    exit: $rc"; }

    rc=0
    (cd "$repo" && "$SDD_SCRIPTS/task-worktree" add plan-a.md 1 not-a-ref >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 2 ]] && pass "add with bad BASE_REF errors with exit 2" || { fail "add with bad BASE_REF errors with exit 2"; echo "    exit: $rc"; }

    # --- add creates the worktree ---
    local wt_path
    wt_path="$(cd "$repo" && "$SDD_SCRIPTS/task-worktree" add plan-a.md 1)"
    if [[ "$wt_path" == "$repo/.superpowers/sdd/plan-a/tasks/task-1" && -d "$wt_path" ]]; then
        pass "add creates worktree at <workspace>/tasks/task-<N>"
    else
        fail "add creates worktree at <workspace>/tasks/task-<N>"
        echo "    got: $wt_path"
    fi

    local branch
    branch="$(cd "$wt_path" && git branch --show-current)"
    if [[ "$branch" == "sdd/plan-a/task-1" ]]; then
        pass "add creates branch sdd/<plan-slug>/task-<N>"
    else
        fail "add creates branch sdd/<plan-slug>/task-<N>"
        echo "    got: $branch"
    fi

    local wt_head
    wt_head="$(cd "$wt_path" && git rev-parse HEAD)"
    local repo_head
    repo_head="$(cd "$repo" && git rev-parse HEAD)"
    if [[ "$wt_head" == "$repo_head" ]]; then
        pass "add defaults BASE_REF to HEAD"
    else
        fail "add defaults BASE_REF to HEAD"
    fi

    # --- add with explicit BASE_REF ---
    local wt2_path
    wt2_path="$(cd "$repo" && "$SDD_SCRIPTS/task-worktree" add plan-a.md 2 "$head1")"
    local wt2_head
    wt2_head="$(cd "$wt2_path" && git rev-parse HEAD)"
    if [[ "$wt2_head" == "$head1" ]]; then
        pass "add honors an explicit BASE_REF"
    else
        fail "add honors an explicit BASE_REF"
        echo "    expected: $head1"
        echo "    got: $wt2_head"
    fi

    # --- add again for the same task errors, existing worktree untouched ---
    rc=0
    (cd "$repo" && "$SDD_SCRIPTS/task-worktree" add plan-a.md 1 >/dev/null 2>&1) || rc=$?
    if [[ "$rc" -eq 3 && -d "$wt_path" ]]; then
        pass "add for an existing task errors with exit 3, leaves worktree intact"
    else
        fail "add for an existing task errors with exit 3, leaves worktree intact"
        echo "    exit: $rc"
    fi

    # --- workspace tasks/ subdir invisible to git status ---
    local status
    status="$(cd "$repo" && git status --porcelain)"
    if [[ "$status" != *".superpowers"* ]]; then
        pass "tasks/ subdir invisible to git status"
    else
        fail "tasks/ subdir invisible to git status"
        echo "    status: $status"
    fi

    # --- remove ---
    rc=0
    output="$(cd "$repo" && "$SDD_SCRIPTS/task-worktree" remove plan-a.md 1)" || rc=$?
    if [[ "$rc" -eq 0 && "$output" == "removed $wt_path" && ! -d "$wt_path" ]]; then
        pass "remove deletes the worktree directory"
    else
        fail "remove deletes the worktree directory"
        echo "    exit: $rc, output: $output"
    fi

    local remaining_branches
    remaining_branches="$(cd "$repo" && git branch --list "sdd/plan-a/task-1")"
    if [[ -z "$remaining_branches" ]]; then
        pass "remove deletes the task branch"
    else
        fail "remove deletes the task branch"
        echo "    still present: $remaining_branches"
    fi

    rc=0
    (cd "$repo" && "$SDD_SCRIPTS/task-worktree" remove plan-a.md 1 >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 3 ]] && pass "remove for a nonexistent task errors with exit 3" || { fail "remove for a nonexistent task errors with exit 3"; echo "    exit: $rc"; }

    echo ""
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "FAILED: $FAILURES assertion(s)."
        exit 1
    fi
    echo "PASS"
}

main "$@"
