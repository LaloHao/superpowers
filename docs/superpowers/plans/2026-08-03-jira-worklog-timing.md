# Jira Worklog Timing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Time each phase of brainstorming → writing-plans → subagent-driven-development (excluding time spent waiting on the human), and offer to publish that time to a Jira issue's worklog at the end of each phase.

**Architecture:** A new `scripts/time-log` shell script provides `start`/`pause`/`resume`/`end`/`summary`/`set-jira` subcommands that append events to a per-topic scratch file (`.superpowers/worklog/<topic>.md`) and compute active duration (excluding paused intervals). The three skills call it at defined checkpoints and, at each phase end, show the computed summary and optionally call the `addWorklogToJiraIssue` MCP tool.

**Tech Stack:** Bash (`set -euo pipefail`, matching `skills/subagent-driven-development/scripts/*`), `awk` for event-log parsing, Markdown skill files, the existing bash test-harness pattern (`tests/claude-code/test-*.sh`).

## Global Constraints

- Fork-local change — no upstream PR process, no eval-evidence requirement, but follow existing repo script/test conventions exactly (shebang, `set -euo pipefail`, exit code convention: `2` usage/missing-input errors, `3` state-conflict/not-found errors).
- Topic slug is the same slug brainstorming/writing-plans already use for spec/plan filenames (`YYYY-MM-DD-<topic>`), derived from the spec or plan filename the skill is working from — never invented separately.
- Worklog file lives at `<repo-root>/.superpowers/worklog/<topic-slug>.md`, git-ignored via a self-ignoring `.gitignore` (`*`) in that directory, same pattern as `scripts/sdd-workspace`.
- Time-tracking granularity is phase-level only: one entry for all of brainstorming, one for all of writing-plans, one per task in subagent-driven-development, one for the final whole-branch review. No per-checklist-item granularity.
- The Jira issue key is asked once per topic, at the first phase-end where it's still `unknown` in the worklog file's header line, and reused (or skipped, if `none`) for every later phase-end of that same topic — never asked again.
- Every phase-end prompts individually whether to publish that phase's time (not batched to one prompt at the very end).
- `.superpowers/worklog/<topic-slug>.md` is **not** deleted by `finishing-a-development-branch` or by subagent-driven-development's Finish step — it persists as a local record after the cycle ends.
- `addWorklogToJiraIssue` requires `cloudId`, `issueIdOrKey`, `timeSpent` (e.g. `"1h 30m"`); accepts optional `started` (ISO 8601) and `commentBody`. `cloudId` is resolved once per conversation via `getAccessibleAtlassianResources` (ask the user if more than one site) — not persisted to the worklog file.

---

### Task 1: `scripts/time-log` — phase timer with pause/resume

**Depends on:** None

**Files:**
- Create: `scripts/time-log`
- Test: `tests/claude-code/test-time-log.sh`
- Modify: `tests/claude-code/run-skill-tests.sh` (register new test)

**Interfaces:**
- Produces (for Tasks 2-4's skill edits to invoke by exact CLI):
  - `time-log start TOPIC PHASE` — creates `<repo-root>/.superpowers/worklog/TOPIC.md` with header `# time-log — topic: TOPIC — jira: unknown` if it doesn't exist, then appends `start PHASE <epoch>`. Exit `2` on usage errors. Exit `3` if PHASE is already open (has a `start` with no matching `end`).
  - `time-log pause TOPIC` — appends `pause <open-phase> <epoch>` for whichever phase is currently open. Exit `3` if no phase is open, or the open phase is already paused.
  - `time-log resume TOPIC` — appends `resume <open-phase> <epoch>`. Exit `3` if no phase is open, or the open phase isn't paused.
  - `time-log end TOPIC` — appends `end <open-phase> <epoch>`, then prints the summary block (below) for that phase. Exit `3` if no phase is open, or the open phase is currently paused (must `resume` before `end`).
  - `time-log summary TOPIC PHASE` — read-only; prints the summary block for an already-`start`ed phase (ended or not — if not yet ended, computes "so far" using the current time). Exit `3` if the phase never started.
  - `time-log set-jira TOPIC VALUE` — rewrites the header line's `jira:` field to `VALUE` (an issue key like `PROJ-123`, or `none`). Exit `3` if the topic's worklog file doesn't exist yet.
  - Summary block format (stdout, one `KEY: value` per line):
    ```
    PHASE: <phase>
    ACTIVE_SECONDS: <integer>
    ACTIVE_HUMAN: <Xh Ym>
    STARTED_ISO: <ISO 8601 UTC, e.g. 2026-08-03T14:00:00.000+0000>
    JIRA: <issue-key|none|unknown>
    ```
    `ACTIVE_SECONDS` = (end or now) − start − Σ(resume − pause) for that phase.

- [ ] **Step 1: Write the failing test**

Create `tests/claude-code/test-time-log.sh`:

```bash
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
```

Make it executable: `chmod +x tests/claude-code/test-time-log.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-time-log.sh`
Expected: FAIL with "No such file or directory" (`scripts/time-log` doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `scripts/time-log`:

```bash
#!/usr/bin/env bash
# Track active work time per phase for a topic, excluding time paused
# (e.g. while waiting on the human partner), so brainstorming,
# writing-plans, and subagent-driven-development can report and optionally
# publish real elapsed time to a Jira worklog.
#
# Usage:
#   time-log start TOPIC PHASE
#   time-log pause TOPIC
#   time-log resume TOPIC
#   time-log end TOPIC
#   time-log summary TOPIC PHASE
#   time-log set-jira TOPIC VALUE
#
# File: <repo-root>/.superpowers/worklog/<TOPIC>.md
# Line 1: "# time-log — topic: <TOPIC> — jira: <ISSUE-KEY|none|unknown>"
# Event lines: "<event> <phase> <epoch-seconds>" (event: start|pause|resume|end)
#
# end/summary print:
#   PHASE: <phase>
#   ACTIVE_SECONDS: <n>
#   ACTIVE_HUMAN: <Xh Ym>
#   STARTED_ISO: <ISO 8601 UTC>
#   JIRA: <issue-key|none|unknown>
set -euo pipefail

usage() {
  echo "usage: time-log start TOPIC PHASE" >&2
  echo "       time-log pause TOPIC" >&2
  echo "       time-log resume TOPIC" >&2
  echo "       time-log end TOPIC" >&2
  echo "       time-log summary TOPIC PHASE" >&2
  echo "       time-log set-jira TOPIC VALUE" >&2
}

worklog_file() {
  local topic=$1
  local root
  root=$(git rev-parse --show-toplevel)
  local dir="$root/.superpowers/worklog"
  mkdir -p "$dir"
  printf '*\n' > "$dir/.gitignore"
  echo "$dir/$topic.md"
}

iso8601_utc() {
  local epoch=$1 out
  out=$(date -u -d "@$epoch" +'%Y-%m-%dT%H:%M:%S.000+0000' 2>/dev/null) && { printf '%s\n' "$out"; return; }
  date -u -r "$epoch" +'%Y-%m-%dT%H:%M:%S.000+0000'
}

human_duration() {
  local seconds=$1
  local h=$(( seconds / 3600 ))
  local m=$(( (seconds % 3600) / 60 ))
  echo "${h}h ${m}m"
}

jira_field() {
  local file=$1
  sed -n '1p' "$file" | sed -n 's/.*— jira: \(.*\)$/\1/p'
}

open_phases() {
  local file=$1
  awk '
    $1=="start" { open[$2]=1 }
    $1=="end"   { delete open[$2] }
    END { for (p in open) print p }
  ' "$file"
}

phase_pause_state() {
  local file=$1 phase=$2
  awk -v p="$phase" '
    $1=="pause" && $2==p  { state="paused" }
    $1=="resume" && $2==p { state="running" }
    END { print (state=="" ? "running" : state) }
  ' "$file"
}

print_summary() {
  local file=$1 phase=$2
  local start_t end_t paused pause_t ev ph t active
  start_t=$(awk -v p="$phase" '$1=="start" && $2==p {print $3; exit}' "$file")
  end_t=$(awk -v p="$phase" '$1=="end" && $2==p {t=$3} END{print t+0}' "$file")
  [ "$end_t" != "0" ] || end_t=$(date +%s)
  paused=0
  pause_t=0
  while read -r ev ph t; do
    case "$ev" in
      pause) pause_t=$t ;;
      resume) paused=$(( paused + (t - pause_t) )) ;;
    esac
  done < <(awk -v p="$phase" '($1=="pause"||$1=="resume") && $2==p' "$file")
  active=$(( end_t - start_t - paused ))
  echo "PHASE: $phase"
  echo "ACTIVE_SECONDS: $active"
  echo "ACTIVE_HUMAN: $(human_duration "$active")"
  echo "STARTED_ISO: $(iso8601_utc "$start_t")"
  echo "JIRA: $(jira_field "$file")"
}

if [ $# -lt 1 ]; then
  usage
  exit 2
fi

cmd=$1
shift

case "$cmd" in
  start)
    [ $# -eq 2 ] || { usage; exit 2; }
    topic=$1; phase=$2
    file=$(worklog_file "$topic")
    [ -f "$file" ] || printf '# time-log — topic: %s — jira: unknown\n' "$topic" > "$file"
    if open_phases "$file" | grep -qx "$phase"; then
      echo "phase already open: $phase" >&2
      exit 3
    fi
    echo "start $phase $(date +%s)" >> "$file"
    ;;
  pause)
    [ $# -eq 1 ] || { usage; exit 2; }
    topic=$1
    file=$(worklog_file "$topic")
    [ -f "$file" ] || { echo "no worklog for topic: $topic" >&2; exit 3; }
    phase=$(open_phases "$file" | head -n1)
    [ -n "$phase" ] || { echo "no phase currently open for topic: $topic" >&2; exit 3; }
    [ "$(phase_pause_state "$file" "$phase")" = "running" ] || { echo "phase already paused: $phase" >&2; exit 3; }
    echo "pause $phase $(date +%s)" >> "$file"
    ;;
  resume)
    [ $# -eq 1 ] || { usage; exit 2; }
    topic=$1
    file=$(worklog_file "$topic")
    [ -f "$file" ] || { echo "no worklog for topic: $topic" >&2; exit 3; }
    phase=$(open_phases "$file" | head -n1)
    [ -n "$phase" ] || { echo "no phase currently open for topic: $topic" >&2; exit 3; }
    [ "$(phase_pause_state "$file" "$phase")" = "paused" ] || { echo "phase is not paused: $phase" >&2; exit 3; }
    echo "resume $phase $(date +%s)" >> "$file"
    ;;
  end)
    [ $# -eq 1 ] || { usage; exit 2; }
    topic=$1
    file=$(worklog_file "$topic")
    [ -f "$file" ] || { echo "no worklog for topic: $topic" >&2; exit 3; }
    phase=$(open_phases "$file" | head -n1)
    [ -n "$phase" ] || { echo "no phase currently open for topic: $topic" >&2; exit 3; }
    [ "$(phase_pause_state "$file" "$phase")" = "running" ] || { echo "phase is paused, resume before ending: $phase" >&2; exit 3; }
    echo "end $phase $(date +%s)" >> "$file"
    print_summary "$file" "$phase"
    ;;
  summary)
    [ $# -eq 2 ] || { usage; exit 2; }
    topic=$1; phase=$2
    file=$(worklog_file "$topic")
    [ -f "$file" ] || { echo "no worklog for topic: $topic" >&2; exit 3; }
    grep -q "^start $phase " "$file" || { echo "no such phase: $phase" >&2; exit 3; }
    print_summary "$file" "$phase"
    ;;
  set-jira)
    [ $# -eq 2 ] || { usage; exit 2; }
    topic=$1; value=$2
    file=$(worklog_file "$topic")
    [ -f "$file" ] || { echo "no worklog for topic: $topic" >&2; exit 3; }
    tmp=$(mktemp)
    printf '# time-log — topic: %s — jira: %s\n' "$topic" "$value" > "$tmp"
    tail -n +2 "$file" >> "$tmp"
    mv "$tmp" "$file"
    ;;
  *)
    usage
    exit 2
    ;;
esac
```

Make it executable: `chmod +x scripts/time-log`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/claude-code/test-time-log.sh`
Expected: PASS (all assertions).

- [ ] **Step 5: Lint the new script**

Run: `scripts/lint-shell.sh scripts/time-log`
Expected: no errors. Fix any ShellCheck findings before continuing.

- [ ] **Step 6: Register the new test in the runner**

In `tests/claude-code/run-skill-tests.sh`, find:

```bash
tests=(
    "test-worktree-path-policy.sh"
    "test-sdd-workspace.sh"
    "test-task-worktree.sh"
    "test-subagent-driven-development.sh"
    "test-writing-plans-parallel.sh"
    "test-brainstorming-parallel.sh"
    "test-sdd-parallel-waves.sh"
)
```

Replace with:

```bash
tests=(
    "test-worktree-path-policy.sh"
    "test-sdd-workspace.sh"
    "test-task-worktree.sh"
    "test-subagent-driven-development.sh"
    "test-writing-plans-parallel.sh"
    "test-brainstorming-parallel.sh"
    "test-sdd-parallel-waves.sh"
    "test-time-log.sh"
)
```

- [ ] **Step 7: Commit**

```bash
git add scripts/time-log tests/claude-code/test-time-log.sh tests/claude-code/run-skill-tests.sh
git commit -m "feat(time-log): add phase timer script with pause/resume for Jira worklog timing"
```

---

### Task 2: `brainstorming` — phase timing and Jira publish

**Depends on:** Task 1

**Files:**
- Modify: `skills/brainstorming/SKILL.md`
- Test: `tests/claude-code/test-brainstorming-worklog.sh`
- Modify: `tests/claude-code/run-skill-tests.sh` (register new test)

**Interfaces:**
- Consumes: `time-log start|pause|resume|end|set-jira` from Task 1 (exact CLI documented above).

- [ ] **Step 1: Write the failing content test**

Create `tests/claude-code/test-brainstorming-worklog.sh`:

```bash
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

assert_contains "time-log start" "Starts the phase timer"
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
```

Make it executable: `chmod +x tests/claude-code/test-brainstorming-worklog.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-brainstorming-worklog.sh`
Expected: FAIL — none of these patterns exist in `skills/brainstorming/SKILL.md` yet.

- [ ] **Step 3: Add phase-start and the pause/resume rule**

In `skills/brainstorming/SKILL.md`, find:

```markdown
**Understanding the idea:**

- Check out the current project state first (files, docs, recent commits).
```

Replace with:

```markdown
**Time tracking:** As soon as you have a working topic slug for this idea
(the same short kebab-case slug you'll use for the spec filename,
`YYYY-MM-DD-<topic>`), run `scripts/time-log start <topic> brainstorming`
before doing anything else. From that point on, every time you are about
to wait on your human partner — an `AskUserQuestion` call, the visual
companion offer, a design-section approval, the spec review gate — run
`scripts/time-log pause <topic>` immediately before, and
`scripts/time-log resume <topic>` immediately after their reply arrives.
This keeps the phase's reported time to your own active work, not their
response time.

**Understanding the idea:**

- Check out the current project state first (files, docs, recent commits).
```

- [ ] **Step 4: Add phase-end and the Jira publish flow**

In `skills/brainstorming/SKILL.md`, find:

```markdown
**Implementation:**

- Invoke the writing-plans skill to create a detailed implementation plan
- Do NOT invoke any other skill. writing-plans is the next step.
```

Replace with:

```markdown
**Time tracking and Jira publish:**

Before invoking writing-plans, run `scripts/time-log end <topic>` — this
prints the phase's active duration and its `JIRA:` field.

- If `JIRA: unknown`: ask "Is this Jira-tracked work? If so, give me the
  issue key (e.g. PROJ-123)." A "no" runs
  `scripts/time-log set-jira <topic> none` and skips the rest of this
  flow — for this topic, no further phase will ask again or offer to
  publish. An issue key runs
  `scripts/time-log set-jira <topic> <ISSUE-KEY>` and continues below.
- If `JIRA: none`: skip straight to Implementation — no summary prompt,
  no publish offer.
- Otherwise (an issue key, from this phase or a prior `set-jira`): show
  the active duration (`ACTIVE_HUMAN`) and ask whether to log it to Jira.
  On yes: resolve `cloudId` via `getAccessibleAtlassianResources` if not
  already resolved this conversation (ask which site if more than one),
  then call `addWorklogToJiraIssue` with that `cloudId`,
  `issueIdOrKey=<the issue>`, `timeSpent=<ACTIVE_HUMAN>`,
  `started=<STARTED_ISO>`, and `commentBody="Design/brainstorming:
  <topic>"`. Report the result. If the Jira MCP connector isn't
  available, say so and continue — the summary you already showed is the
  fallback.

**Implementation:**

- Invoke the writing-plans skill to create a detailed implementation plan
- Do NOT invoke any other skill. writing-plans is the next step.
```

- [ ] **Step 5: Register the new test in the runner**

In `tests/claude-code/run-skill-tests.sh`, find (after Task 1's edit):

```bash
tests=(
    "test-worktree-path-policy.sh"
    "test-sdd-workspace.sh"
    "test-task-worktree.sh"
    "test-subagent-driven-development.sh"
    "test-writing-plans-parallel.sh"
    "test-brainstorming-parallel.sh"
    "test-sdd-parallel-waves.sh"
    "test-time-log.sh"
)
```

Replace with:

```bash
tests=(
    "test-worktree-path-policy.sh"
    "test-sdd-workspace.sh"
    "test-task-worktree.sh"
    "test-subagent-driven-development.sh"
    "test-writing-plans-parallel.sh"
    "test-brainstorming-parallel.sh"
    "test-sdd-parallel-waves.sh"
    "test-time-log.sh"
    "test-brainstorming-worklog.sh"
)
```

(If a parallel task has already appended a different entry here, add
`"test-brainstorming-worklog.sh"` as the next line after whatever is
already there — read the file's actual current content before editing,
don't blindly overwrite based on this snippet.)

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/claude-code/test-brainstorming-worklog.sh`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add skills/brainstorming/SKILL.md tests/claude-code/test-brainstorming-worklog.sh tests/claude-code/run-skill-tests.sh
git commit -m "feat(brainstorming): time the phase and offer to publish to Jira worklog"
```

---

### Task 3: `writing-plans` — phase timing and Jira publish

**Depends on:** Task 1

**Files:**
- Modify: `skills/writing-plans/SKILL.md`
- Test: `tests/claude-code/test-writing-plans-worklog.sh`
- Modify: `tests/claude-code/run-skill-tests.sh` (register new test)

**Interfaces:**
- Consumes: `time-log start|pause|resume|end|set-jira` from Task 1.

- [ ] **Step 1: Write the failing content test**

Create `tests/claude-code/test-writing-plans-worklog.sh`:

```bash
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
```

Make it executable: `chmod +x tests/claude-code/test-writing-plans-worklog.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-writing-plans-worklog.sh`
Expected: FAIL — none of these patterns exist in `skills/writing-plans/SKILL.md` yet.

- [ ] **Step 3: Add phase-start, pause/resume, phase-end, and the Jira publish flow**

In `skills/writing-plans/SKILL.md`, find:

```markdown
**Save plans to:** `docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md`
- (User preferences for plan location override this default)

## Scope Check
```

Replace with:

```markdown
**Save plans to:** `docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md`
- (User preferences for plan location override this default)

**Time tracking:** Derive `<topic>` from the spec filename you were given
(the slug between the date and `-design`, e.g. `2026-08-03-my-feature`
from `docs/superpowers/specs/2026-08-03-my-feature-design.md`), then run
`scripts/time-log start <topic> writing-plans` before doing anything
else. This skill has one real point where it waits on your human
partner: the Subagent-Driven-vs-Inline-Execution offer in Execution
Handoff. Run `scripts/time-log pause <topic>` immediately before making
that offer, and `scripts/time-log resume <topic>` immediately after they
answer.

## Scope Check
```

- [ ] **Step 4: Add phase-end before the execution-choice offer**

In `skills/writing-plans/SKILL.md`, find:

```markdown
## Execution Handoff

After saving the plan, offer execution choice:

**"Plan complete and saved to `docs/superpowers/plans/<filename>.md`. Two execution options:**
```

Replace with:

```markdown
## Execution Handoff

After saving the plan, run `scripts/time-log end <topic>` — this prints
the phase's active duration and its `JIRA:` field.

- If `JIRA: unknown`: ask "Is this Jira-tracked work? If so, give me the
  issue key (e.g. PROJ-123)." A "no" runs
  `scripts/time-log set-jira <topic> none` and skips the rest of this
  flow. An issue key runs `scripts/time-log set-jira <topic> <ISSUE-KEY>`
  and continues below.
- If `JIRA: none`: skip straight to the execution-choice offer below — no
  summary prompt, no publish offer.
- Otherwise (an issue key): show the active duration (`ACTIVE_HUMAN`) and
  ask whether to log it to Jira. On yes: resolve `cloudId` via
  `getAccessibleAtlassianResources` if not already resolved this
  conversation (ask which site if more than one), then call
  `addWorklogToJiraIssue` with that `cloudId`, `issueIdOrKey=<the issue>`,
  `timeSpent=<ACTIVE_HUMAN>`, `started=<STARTED_ISO>`, and
  `commentBody="Implementation planning: <topic>"`. Report the result. If
  the Jira MCP connector isn't available, say so and continue.

Run `scripts/time-log pause <topic>` (see Time tracking above), then
offer execution choice:

**"Plan complete and saved to `docs/superpowers/plans/<filename>.md`. Two execution options:**
```

- [ ] **Step 5: Register the new test in the runner**

In `tests/claude-code/run-skill-tests.sh`, read the file's actual current
`tests=(...)` array (Task 2 may have already appended
`"test-brainstorming-worklog.sh"` — this task runs independently of Task
2, so add your line after whatever is currently last, don't assume a
specific prior state) and append `"test-writing-plans-worklog.sh"` as the
next entry.

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/claude-code/test-writing-plans-worklog.sh`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add skills/writing-plans/SKILL.md tests/claude-code/test-writing-plans-worklog.sh tests/claude-code/run-skill-tests.sh
git commit -m "feat(writing-plans): time the phase and offer to publish to Jira worklog"
```

---

### Task 4: `subagent-driven-development` — per-task and final-review timing and Jira publish

**Depends on:** Task 1

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md`
- Test: `tests/claude-code/test-sdd-worklog.sh`
- Modify: `tests/claude-code/run-skill-tests.sh` (register new test)

**Interfaces:**
- Consumes: `time-log start|pause|resume|end|set-jira` from Task 1.

- [ ] **Step 1: Write the failing content test**

Create `tests/claude-code/test-sdd-worklog.sh`:

```bash
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
```

Make it executable: `chmod +x tests/claude-code/test-sdd-worklog.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-sdd-worklog.sh`
Expected: FAIL — none of these patterns exist in `skills/subagent-driven-development/SKILL.md` yet.

- [ ] **Step 3: Add a Worklog Timing section and phase-start at dispatch**

In `skills/subagent-driven-development/SKILL.md`, find:

```markdown
## Wave Dispatch

Every task declares `Depends on: Task N, Task M` or `Depends on: None`.
```

Replace with:

```markdown
## Worklog Timing

Derive `<topic>` from the plan filename (the slug between the date and
the rest, e.g. `2026-08-03-my-feature` from
`docs/superpowers/plans/2026-08-03-my-feature.md` — the same slug
brainstorming and writing-plans already used for this topic's spec and
plan). Run `scripts/time-log start <topic> task-N` at the same point you
record BASE for task N (Task Loop, step 1). This skill's "continuous
execution" principle means routine dispatch/review/fix-loop activity is
never a wait point — but relaying an implementer's question to your human
partner, or a plan-vs-review conflict that needs their decision, are real
waits: run `scripts/time-log pause <topic>` immediately before either,
and `scripts/time-log resume <topic>` immediately after their reply.

Run `scripts/time-log end <topic>` when task N is marked complete in the
ledger (Task Loop, step 5), before appending the ledger line. This prints
the task's active duration and its `JIRA:` field.

- If `JIRA: unknown`: ask "Is this Jira-tracked work? If so, give me the
  issue key (e.g. PROJ-123)." A "no" runs
  `scripts/time-log set-jira <topic> none` and skips the rest of this
  flow — for the rest of this plan (including the final review below),
  no further prompt or publish offer.
- If `JIRA: none`: skip straight to the ledger bookkeeping — no summary
  prompt, no publish offer.
- Otherwise (an issue key): show the active duration (`ACTIVE_HUMAN`) and
  ask whether to log it to Jira. On yes: resolve `cloudId` via
  `getAccessibleAtlassianResources` if not already resolved this
  conversation (ask which site if more than one), then call
  `addWorklogToJiraIssue` with that `cloudId`, `issueIdOrKey=<the
  issue>`, `timeSpent=<ACTIVE_HUMAN>`, `started=<STARTED_ISO>`, and
  `commentBody="Task N: <task title>"`. Report the result. If the Jira
  MCP connector isn't available, say so and continue.

Run the same `start`/pause-resume/`end`/publish cycle once more around
the whole-branch final review, using phase `final-review`: `start` right
before dispatching the final code reviewer, `end` right after the final
review is clean and any fixes are merged (before deleting the plan's
workspace), with `commentBody="Final review: <topic>"`.

## Wave Dispatch

Every task declares `Depends on: Task N, Task M` or `Depends on: None`.
```

- [ ] **Step 4: Register the new test in the runner**

In `tests/claude-code/run-skill-tests.sh`, read the file's actual current
`tests=(...)` array (Tasks 2 and 3 run independently of this task and may
have already appended their own entries — add your line after whatever
is currently last, don't assume a specific prior state) and append
`"test-sdd-worklog.sh"` as the next entry.

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/claude-code/test-sdd-worklog.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md tests/claude-code/test-sdd-worklog.sh tests/claude-code/run-skill-tests.sh
git commit -m "feat(subagent-driven-development): time each task and final review, offer Jira worklog publish"
```

---

## Post-plan note (not a task — informational)

Tasks 2, 3, and 4 all read-then-append the same array in
`tests/claude-code/run-skill-tests.sh`. If they run in the same parallel
wave (all three list `Depends on: Task 1` and nothing else, so
`subagent-driven-development`'s wave dispatch may batch them together),
each task's worktree only sees the file as of the wave's start — the
merge-on-completion step in Wave Dispatch handles this the same way it
already handles any other shared-file edit across parallel tasks: each
task's implementer reads the file's actual current content in its own
worktree at merge time is not guaranteed to include a sibling task's
not-yet-merged edit, so a trivial merge conflict on this one array is
expected and should be resolved by keeping both appended lines, in
either order.
