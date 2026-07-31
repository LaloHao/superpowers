#!/usr/bin/env bash
# Tests for scripts/time-log: phase timing with pause/resume, used by
# brainstorming, writing-plans, and subagent-driven-development to report
# and optionally publish active work time to a Jira worklog.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TIME_LOG="$REPO_ROOT/scripts/time-log"

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

field() {
    # field KEY <<< "$summary_output"
    sed -n "s/^$1: //p"
}

main() {
    echo "=== Test: time-log ==="

    TEST_ROOT="$(mktemp -d)"
    trap cleanup EXIT

    git init -q -b main "$TEST_ROOT/repo"
    local repo
    repo="$(cd "$TEST_ROOT/repo" && git rev-parse --show-toplevel)"

    # --- usage validation ---
    local rc=0
    (cd "$repo" && "$TIME_LOG" >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 2 ]] && pass "no args errors with exit 2" || { fail "no args errors with exit 2"; echo "    exit: $rc"; }

    rc=0
    (cd "$repo" && "$TIME_LOG" bogus topic-a >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 2 ]] && pass "unknown subcommand errors with exit 2" || { fail "unknown subcommand errors with exit 2"; echo "    exit: $rc"; }

    rc=0
    (cd "$repo" && "$TIME_LOG" start topic-a >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 2 ]] && pass "start with missing PHASE errors with exit 2" || { fail "start with missing PHASE errors with exit 2"; echo "    exit: $rc"; }

    # --- start creates the worklog file ---
    (cd "$repo" && "$TIME_LOG" start topic-a brainstorming >/dev/null)
    local file="$repo/.superpowers/worklog/topic-a.md"
    if [[ -f "$file" ]] && head -n1 "$file" | grep -qF -- "— topic: topic-a — jira: unknown"; then
        pass "start creates worklog file with jira: unknown header"
    else
        fail "start creates worklog file with jira: unknown header"
        echo "    contents: $(cat "$file" 2>/dev/null)"
    fi

    # --- start twice for the same open phase errors ---
    rc=0
    (cd "$repo" && "$TIME_LOG" start topic-a brainstorming >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 3 ]] && pass "start on an already-open phase errors with exit 3" || { fail "start on an already-open phase errors with exit 3"; echo "    exit: $rc"; }

    # --- pause/resume state machine ---
    rc=0
    (cd "$repo" && "$TIME_LOG" start topic-b other-phase >/dev/null 2>&1) || rc=$?
    (cd "$repo" && "$TIME_LOG" pause topic-a >/dev/null)
    rc=0
    (cd "$repo" && "$TIME_LOG" pause topic-a >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 3 ]] && pass "pause on an already-paused phase errors with exit 3" || { fail "pause on an already-paused phase errors with exit 3"; echo "    exit: $rc"; }

    (cd "$repo" && "$TIME_LOG" resume topic-a >/dev/null)
    rc=0
    (cd "$repo" && "$TIME_LOG" resume topic-a >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 3 ]] && pass "resume with no pending pause errors with exit 3" || { fail "resume with no pending pause errors with exit 3"; echo "    exit: $rc"; }

    rc=0
    (cd "$repo" && "$TIME_LOG" pause topic-does-not-exist >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 3 ]] && pass "pause on a nonexistent topic errors with exit 3" || { fail "pause on a nonexistent topic errors with exit 3"; echo "    exit: $rc"; }

    # --- end while paused errors ---
    (cd "$repo" && "$TIME_LOG" pause topic-a >/dev/null)
    rc=0
    (cd "$repo" && "$TIME_LOG" end topic-a >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 3 ]] && pass "end while paused errors with exit 3" || { fail "end while paused errors with exit 3"; echo "    exit: $rc"; }
    (cd "$repo" && "$TIME_LOG" resume topic-a >/dev/null)

    # --- end with no phase open errors ---
    rc=0
    (cd "$repo" && "$TIME_LOG" end topic-does-not-exist >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 3 ]] && pass "end on a nonexistent topic errors with exit 3" || { fail "end on a nonexistent topic errors with exit 3"; echo "    exit: $rc"; }

    (cd "$repo" && "$TIME_LOG" end topic-a >/dev/null)
    rc=0
    (cd "$repo" && "$TIME_LOG" end topic-a >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 3 ]] && pass "end with no phase open errors with exit 3" || { fail "end with no phase open errors with exit 3"; echo "    exit: $rc"; }

    # --- summary on a never-started phase errors ---
    rc=0
    (cd "$repo" && "$TIME_LOG" summary topic-a no-such-phase >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 3 ]] && pass "summary on a never-started phase errors with exit 3" || { fail "summary on a never-started phase errors with exit 3"; echo "    exit: $rc"; }

    # --- duration math, via a hand-crafted worklog file (deterministic, no real waiting) ---
    local math_file="$repo/.superpowers/worklog/topic-math.md"
    mkdir -p "$repo/.superpowers/worklog"
    cat > "$math_file" <<'EOF'
# time-log — topic: topic-math — jira: unknown
start task-1 1000
pause task-1 1100
resume task-1 1150
end task-1 2000
EOF
    local summary_out
    summary_out="$(cd "$repo" && "$TIME_LOG" summary topic-math task-1)"
    # total window 1000..2000 = 1000s; paused 1100..1150 = 50s; active = 950s = 0h 15m
    local active_seconds active_human
    active_seconds="$(printf '%s\n' "$summary_out" | field ACTIVE_SECONDS)"
    active_human="$(printf '%s\n' "$summary_out" | field ACTIVE_HUMAN)"
    if [[ "$active_seconds" == "950" ]]; then
        pass "summary subtracts paused interval from active seconds"
    else
        fail "summary subtracts paused interval from active seconds"
        echo "    got ACTIVE_SECONDS=$active_seconds"
    fi
    if [[ "$active_human" == "0h 15m" ]]; then
        pass "summary formats active duration as Xh Ym"
    else
        fail "summary formats active duration as Xh Ym"
        echo "    got ACTIVE_HUMAN=$active_human"
    fi
    local started_iso
    started_iso="$(printf '%s\n' "$summary_out" | field STARTED_ISO)"
    if [[ "$started_iso" == "1970-01-01T00:16:40.000+0000" ]]; then
        pass "summary reports STARTED_ISO as ISO 8601 UTC"
    else
        fail "summary reports STARTED_ISO as ISO 8601 UTC"
        echo "    got STARTED_ISO=$started_iso"
    fi

    # --- summary is read-only (no lines appended) ---
    local lines_before lines_after
    lines_before="$(wc -l < "$math_file" | tr -d ' ')"
    (cd "$repo" && "$TIME_LOG" summary topic-math task-1 >/dev/null)
    lines_after="$(wc -l < "$math_file" | tr -d ' ')"
    if [[ "$lines_before" == "$lines_after" ]]; then
        pass "summary does not append to the worklog file"
    else
        fail "summary does not append to the worklog file"
        echo "    before=$lines_before after=$lines_after"
    fi

    # --- restarted phase: summary uses the most recent start/end window ---
    local restart_file="$repo/.superpowers/worklog/topic-restart.md"
    cat > "$restart_file" <<'EOF'
# time-log — topic: topic-restart — jira: unknown
start p1 1000
end p1 1100
start p1 2000
end p1 2100
EOF
    local restart_out restart_active
    restart_out="$(cd "$repo" && "$TIME_LOG" summary topic-restart p1)"
    restart_active="$(printf '%s\n' "$restart_out" | field ACTIVE_SECONDS)"
    if [[ "$restart_active" == "100" ]]; then
        pass "summary uses the most recent start for a restarted phase"
    else
        fail "summary uses the most recent start for a restarted phase"
        echo "    got ACTIVE_SECONDS=$restart_active"
    fi

    # --- set-jira ---
    (cd "$repo" && "$TIME_LOG" set-jira topic-math PROJ-123 >/dev/null)
    local jira_field
    jira_field="$(cd "$repo" && "$TIME_LOG" summary topic-math task-1 | field JIRA)"
    if [[ "$jira_field" == "PROJ-123" ]]; then
        pass "set-jira updates the header field, reflected in summary"
    else
        fail "set-jira updates the header field, reflected in summary"
        echo "    got JIRA=$jira_field"
    fi

    rc=0
    (cd "$repo" && "$TIME_LOG" set-jira topic-does-not-exist PROJ-999 >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 3 ]] && pass "set-jira on a nonexistent topic errors with exit 3" || { fail "set-jira on a nonexistent topic errors with exit 3"; echo "    exit: $rc"; }

    # --- two topics resolve to two distinct files ---
    if [[ -f "$repo/.superpowers/worklog/topic-a.md" && -f "$repo/.superpowers/worklog/topic-b.md" ]]; then
        pass "two topics resolve to two distinct worklog files"
    else
        fail "two topics resolve to two distinct worklog files"
    fi

    # --- worklog dir invisible to git status ---
    local status
    status="$(cd "$repo" && git status --porcelain)"
    if [[ "$status" != *".superpowers"* ]]; then
        pass "worklog dir invisible to git status"
    else
        fail "worklog dir invisible to git status"
        echo "    status: $status"
    fi

    echo ""
    if [[ "$FAILURES" -ne 0 ]]; then
        echo "FAILED: $FAILURES assertion(s)."
        exit 1
    fi
    echo "PASS"
}

main "$@"
