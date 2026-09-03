# Worklog Timing Single Upfront Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the worklog timing feature's per-phase Jira prompting with a single upfront question per topic (track? which ticket?), after which every later phase behaves automatically — no instrumentation, tracked-only, or tracked-and-auto-published.

**Architecture:** `scripts/time-log` gains a read-only `status` subcommand and a relaxed `set-jira` (creates the file if missing), giving the three skills a way to check/record a topic's tracking decision before any timer starts. All three skills' "Time tracking" and phase-end sections are rewritten around a shared four-state flow: `unknown` (ask now) → `disabled` (zero calls) / `none` (track, never publish) / `<ISSUE-KEY>` (track, auto-publish, no confirmation).

**Tech Stack:** Bash (`set -euo pipefail`, matching the existing `scripts/time-log`), Markdown skill files, the existing `tests/claude-code/test-*.sh` bash harness.

## Global Constraints

- Fork-local change — no upstream PR process, no eval-evidence requirement, but follow existing repo script/test conventions exactly (exit code `2` for usage errors, `3` for state/not-found errors).
- Four `jira:` header states: `unknown` (not yet asked) / `disabled` (declined — zero `time-log` calls anywhere in the topic from here on) / `none` (tracking wanted, no ticket — track and show duration, never publish) / `<ISSUE-KEY>` (tracking wanted with ticket — track and auto-publish every phase end, no per-phase confirmation).
- The upfront question is asked exactly once per topic (not per conversation) — the first skill to see `JIRA: unknown` for a topic asks it; every later phase of every skill in that same topic reuses the resolved state via `time-log status` without asking again.
- **Known bug fix included in this plan:** `writing-plans`'s current Execution Handoff calls `time-log end` and then `time-log pause` on the now-closed phase — pausing after ending is invalid (the phase is no longer open). This plan reorders it: pause before offering execution choice, resume after the answer, end after that. Task 3 implements this fix as part of its rewrite (it touches the same block regardless).
- `getAccessibleAtlassianResources`/`cloudId` resolution behavior (once per conversation, ask only if genuinely ambiguous) is unchanged from the existing feature.

---

### Task 1: `scripts/time-log` — `status` subcommand and file-creating `set-jira`

**Depends on:** None

**Files:**
- Modify: `scripts/time-log`
- Modify: `tests/claude-code/test-time-log.sh`

**Interfaces:**
- Produces (for Tasks 2-4 to invoke by exact CLI):
  - `time-log status TOPIC` — prints `JIRA: <value>` read from the topic's worklog header, or `JIRA: unknown` if the topic's worklog file doesn't exist yet (and does **not** create the file in that case). Exit `2` on usage errors (wrong arg count). Never exits 3.
  - `time-log set-jira TOPIC VALUE` — now creates the worklog file (with the standard `# time-log — topic: TOPIC — jira: unknown` header, exactly like `start` does) if it doesn't exist yet, instead of exiting 3. Otherwise unchanged: rewrites only the header line's `jira:` field, preserving all event lines.
  - `start`/`pause`/`resume`/`end`/`summary` are unchanged.

- [ ] **Step 1: Write the failing test**

In `tests/claude-code/test-time-log.sh`, find:

```bash
    rc=0
    (cd "$repo" && "$TIME_LOG" set-jira topic-does-not-exist PROJ-999 >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 3 ]] && pass "set-jira on a nonexistent topic errors with exit 3" || { fail "set-jira on a nonexistent topic errors with exit 3"; echo "    exit: $rc"; }

    # --- multiple open phases: PHASE arg required, and targets only the named phase ---
```

Replace with:

```bash
    # --- status subcommand ---
    rc=0
    (cd "$repo" && "$TIME_LOG" status >/dev/null 2>&1) || rc=$?
    [[ "$rc" -eq 2 ]] && pass "status with missing TOPIC errors with exit 2" || { fail "status with missing TOPIC errors with exit 2"; echo "    exit: $rc"; }

    local status_out
    status_out="$(cd "$repo" && "$TIME_LOG" status topic-never-seen)"
    if [[ "$status_out" == "JIRA: unknown" ]]; then
        pass "status on a nonexistent topic prints JIRA: unknown"
    else
        fail "status on a nonexistent topic prints JIRA: unknown"
        echo "    got: $status_out"
    fi
    if [[ ! -f "$repo/.superpowers/worklog/topic-never-seen.md" ]]; then
        pass "status on a nonexistent topic does not create a worklog file"
    else
        fail "status on a nonexistent topic does not create a worklog file"
    fi

    status_out="$(cd "$repo" && "$TIME_LOG" status topic-math)"
    if [[ "$status_out" == "JIRA: PROJ-123" ]]; then
        pass "status on an existing topic prints its resolved jira field"
    else
        fail "status on an existing topic prints its resolved jira field"
        echo "    got: $status_out"
    fi

    # --- set-jira creates the worklog file if it doesn't exist yet ---
    (cd "$repo" && "$TIME_LOG" set-jira topic-fresh disabled >/dev/null)
    if [[ -f "$repo/.superpowers/worklog/topic-fresh.md" ]]; then
        pass "set-jira creates the worklog file when it doesn't exist yet"
    else
        fail "set-jira creates the worklog file when it doesn't exist yet"
    fi
    status_out="$(cd "$repo" && "$TIME_LOG" status topic-fresh)"
    if [[ "$status_out" == "JIRA: disabled" ]]; then
        pass "set-jira on a fresh topic sets the given value (e.g. disabled)"
    else
        fail "set-jira on a fresh topic sets the given value (e.g. disabled)"
        echo "    got: $status_out"
    fi

    # --- multiple open phases: PHASE arg required, and targets only the named phase ---
```

This places the new assertions right after the existing `set-jira topic-math PROJ-123` block (so `status topic-math` correctly finds `PROJ-123`), and removes the old "set-jira on a nonexistent topic errors with exit 3" assertion — that behavior is intentionally changing in this task (set-jira on a nonexistent topic now succeeds and creates the file, it no longer errors).

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-time-log.sh`
Expected: FAIL — `status` doesn't exist yet (unknown subcommand, exit 2 mismatched to the wrong assertions), and the removed "set-jira on a nonexistent topic errors with exit 3" assertion is gone so that specific old check no longer runs.

- [ ] **Step 3: Implement `status` and relax `set-jira`**

In `scripts/time-log`, find:

```bash
usage() {
  echo "usage: time-log start TOPIC PHASE" >&2
  echo "       time-log pause TOPIC [PHASE]" >&2
  echo "       time-log resume TOPIC [PHASE]" >&2
  echo "       time-log end TOPIC [PHASE]" >&2
  echo "       time-log summary TOPIC PHASE" >&2
  echo "       time-log set-jira TOPIC VALUE" >&2
}
```

Replace with:

```bash
usage() {
  echo "usage: time-log start TOPIC PHASE" >&2
  echo "       time-log pause TOPIC [PHASE]" >&2
  echo "       time-log resume TOPIC [PHASE]" >&2
  echo "       time-log end TOPIC [PHASE]" >&2
  echo "       time-log summary TOPIC PHASE" >&2
  echo "       time-log status TOPIC" >&2
  echo "       time-log set-jira TOPIC VALUE" >&2
}
```

Then find:

```bash
  set-jira)
    [ $# -eq 2 ] || { usage; exit 2; }
    topic=$1; value=$2
    file=$(worklog_file "$topic")
    [ -f "$file" ] || { echo "no worklog for topic: $topic" >&2; exit 3; }
    tmp=$(mktemp)
```

Replace with:

```bash
  status)
    [ $# -eq 1 ] || { usage; exit 2; }
    topic=$1
    file=$(worklog_file "$topic")
    if [ -f "$file" ]; then
      echo "JIRA: $(jira_field "$file")"
    else
      echo "JIRA: unknown"
    fi
    ;;
  set-jira)
    [ $# -eq 2 ] || { usage; exit 2; }
    topic=$1; value=$2
    file=$(worklog_file "$topic")
    [ -f "$file" ] || printf '# time-log — topic: %s — jira: unknown\n' "$topic" > "$file"
    tmp=$(mktemp)
```

Then find the header comment block:

```bash
# Usage:
#   time-log start TOPIC PHASE
#   time-log pause TOPIC [PHASE]
#   time-log resume TOPIC [PHASE]
#   time-log end TOPIC [PHASE]
#   time-log summary TOPIC PHASE
#   time-log set-jira TOPIC VALUE
```

Replace with:

```bash
# Usage:
#   time-log start TOPIC PHASE
#   time-log pause TOPIC [PHASE]
#   time-log resume TOPIC [PHASE]
#   time-log end TOPIC [PHASE]
#   time-log summary TOPIC PHASE
#   time-log status TOPIC
#   time-log set-jira TOPIC VALUE
#
# status prints "JIRA: <value>" for TOPIC's header field, or
# "JIRA: unknown" if TOPIC has no worklog file yet (without creating
# one) — the read-only check the three skills use before deciding
# whether to ask about tracking. set-jira creates TOPIC's worklog file
# (with a default "jira: unknown" header) if it doesn't exist yet,
# instead of erroring.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/claude-code/test-time-log.sh`
Expected: PASS (all assertions).

- [ ] **Step 5: Lint the changed script**

Run: `scripts/lint-shell.sh scripts/time-log`
Expected: no errors. Fix any ShellCheck findings before continuing.

- [ ] **Step 6: Commit**

```bash
git add scripts/time-log tests/claude-code/test-time-log.sh
git commit -m "feat(time-log): add status subcommand, let set-jira create a missing worklog file"
```

---

### Task 2: `brainstorming` — single upfront tracking prompt

**Depends on:** Task 1

**Files:**
- Modify: `skills/brainstorming/SKILL.md`
- Modify: `tests/claude-code/test-brainstorming-worklog.sh`

**Interfaces:**
- Consumes: `time-log status|set-jira|start|pause|resume|end` from Task 1 (exact CLI documented above).

- [ ] **Step 1: Rewrite the content test**

Replace the entire contents of `tests/claude-code/test-brainstorming-worklog.sh` with:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-brainstorming-worklog.sh`
Expected: FAIL — none of the new patterns exist in `skills/brainstorming/SKILL.md` yet, and the two `assert_not_contains` checks currently fail (the old text is still present).

- [ ] **Step 3: Replace the Checklist item 1 line**

In `skills/brainstorming/SKILL.md`, find:

```markdown
1. **Start time tracking and explore project context** — run `scripts/time-log start <topic> brainstorming` as soon as you have a working topic slug, then check files, docs, recent commits
```

Replace with:

```markdown
1. **Resolve time tracking, then explore project context** — as soon as you have a working topic slug, run `scripts/time-log status <topic>`; resolve tracking per the Time tracking section below, then check files, docs, recent commits
```

- [ ] **Step 4: Replace the "Time tracking:" paragraph**

In `skills/brainstorming/SKILL.md`, find:

```markdown
**Time tracking:** Checklist item 1 above starts timing
(`scripts/time-log start <topic> brainstorming`) — the topic slug is the
same short kebab-case slug you'll use for the spec filename,
`YYYY-MM-DD-<topic>`. Immediately after that call, if your human partner
already mentioned a Jira issue key anywhere in the conversation so far
(e.g. in their opening request), run
`scripts/time-log set-jira <topic> <ISSUE-KEY>` right now — don't wait
for the end-of-phase prompt to capture it. From that point on, every time
you are about to wait on your human partner — an `AskUserQuestion` call,
the visual companion offer, a design-section approval, the spec review
gate — run `scripts/time-log pause <topic>` immediately before, and
`scripts/time-log resume <topic>` immediately after their reply arrives.
This keeps the phase's reported time to your own active work, not their
response time.
```

Replace with:

```markdown
**Time tracking:** Checklist item 1 above runs `scripts/time-log status
<topic>` before anything else — the topic slug is the same short
kebab-case slug you'll use for the spec filename, `YYYY-MM-DD-<topic>`.

- If it prints `JIRA: unknown` (first time this topic has been seen):
  ask "Do you want time tracked for this task?" A "no" runs
  `scripts/time-log set-jira <topic> disabled` — for the rest of this
  topic, in every phase of every skill, make zero `time-log` calls and
  skip this entire flow, with no further asking. A "yes" asks "What Jira
  ticket does this correspond to? (or say it doesn't apply)" — a ticket
  key runs `scripts/time-log set-jira <topic> <ISSUE-KEY>`; no ticket
  runs `scripts/time-log set-jira <topic> none`. Only if the result
  isn't `disabled`, now run `scripts/time-log start <topic>
  brainstorming`.
- If it prints `JIRA: disabled`: make no further `time-log` calls this
  phase at all — proceed straight to exploring project context.
- Otherwise (`JIRA: none` or an issue key, from an earlier phase or just
  resolved above): run `scripts/time-log start <topic> brainstorming`
  and continue tracking below.

Once tracking is active, every time you are about to wait on your human
partner — an `AskUserQuestion` call, the visual companion offer, a
design-section approval, the spec review gate — run `scripts/time-log
pause <topic>` immediately before, and `scripts/time-log resume <topic>`
immediately after their reply arrives. This keeps the phase's reported
time to your own active work, not their response time.
```

- [ ] **Step 5: Replace the "Time tracking and Jira publish:" block**

In `skills/brainstorming/SKILL.md`, find:

```markdown
**Time tracking and Jira publish:**

Before invoking writing-plans, run `scripts/time-log end <topic>`. If it
fails (exit 3 — no phase was ever started, e.g. checklist item 1's
`time-log start` call was skipped), do not silently continue: tell your
human partner "I wasn't able to track time automatically for this phase
— want to log an approximate duration manually?" If yes, ask for the
duration directly (e.g. "2h 30m") and use it in place of `ACTIVE_HUMAN`
below (use "now" in place of `STARTED_ISO`); if no, skip the rest of this
flow and go straight to Implementation. Otherwise, `time-log end`
printed the phase's active duration and its `JIRA:` field — continue
below.

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
```

Replace with:

```markdown
**Time tracking and Jira publish:**

If tracking was disabled for this topic, skip straight to Implementation
— no `time-log end` call, nothing to report.

Otherwise, run `scripts/time-log end <topic>`. If it fails (exit 3 — no
phase was ever started, e.g. checklist item 1's `time-log start` call
was skipped), do not silently continue: tell your human partner "I
wasn't able to track time automatically for this phase — want to log an
approximate duration manually?" If yes, ask for the duration directly
(e.g. "2h 30m") and use it in place of `ACTIVE_HUMAN` below (use "now"
in place of `STARTED_ISO`); if no, skip the rest of this flow and go
straight to Implementation. Otherwise, `time-log end` printed the
phase's active duration and its `JIRA:` field — continue below.

- If `JIRA: none`: show the active duration (`ACTIVE_HUMAN`) to your
  human partner, then go straight to Implementation — nothing to
  publish.
- Otherwise (an issue key): resolve `cloudId` via
  `getAccessibleAtlassianResources` if not already resolved this
  conversation (ask which site if more than one), then call
  `addWorklogToJiraIssue` with that `cloudId`, `issueIdOrKey=<the
  issue>`, `timeSpent=<ACTIVE_HUMAN>`, `started=<STARTED_ISO>`, and
  `commentBody="Design/brainstorming: <topic>"`. Report the result — no
  confirmation prompt, the upfront answer already was the consent. If
  the Jira MCP connector isn't available, say so and continue.
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/claude-code/test-brainstorming-worklog.sh`
Expected: PASS (all assertions).

- [ ] **Step 7: Commit**

```bash
git add skills/brainstorming/SKILL.md tests/claude-code/test-brainstorming-worklog.sh
git commit -m "feat(brainstorming): ask time-tracking once upfront, auto-publish without per-phase confirmation"
```

---

### Task 3: `writing-plans` — single upfront tracking prompt (+ pause/end ordering fix)

**Depends on:** Task 1

**Files:**
- Modify: `skills/writing-plans/SKILL.md`
- Modify: `tests/claude-code/test-writing-plans-worklog.sh`

**Interfaces:**
- Consumes: `time-log status|set-jira|start|pause|resume|end` from Task 1.

- [ ] **Step 1: Rewrite the content test**

Replace the entire contents of `tests/claude-code/test-writing-plans-worklog.sh` with:

```bash
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

pause_line=$(grep -n "time-log pause <topic> now" "$SKILL" | head -1 | cut -d: -f1)
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-writing-plans-worklog.sh`
Expected: FAIL — none of the new patterns exist yet, and the ordering check can't find either marker line.

- [ ] **Step 3: Replace the "Announce at start" block**

In `skills/writing-plans/SKILL.md`, find:

```markdown
**Announce at start:** "I'm using the writing-plans skill to create the
implementation plan." Immediately after announcing, derive `<topic>`
from the spec filename you were given (the slug between the date and
`-design`, e.g. `2026-08-03-my-feature` from
`docs/superpowers/specs/2026-08-03-my-feature-design.md`) and run
`scripts/time-log start <topic> writing-plans` — before doing anything
else. If your human partner already mentioned a Jira issue key anywhere
in the conversation before this point, run
`scripts/time-log set-jira <topic> <ISSUE-KEY>` right now too — don't
wait for the end-of-phase prompt to capture it.
```

Replace with:

```markdown
**Announce at start:** "I'm using the writing-plans skill to create the
implementation plan." Immediately after announcing, derive `<topic>`
from the spec filename you were given (the slug between the date and
`-design`, e.g. `2026-08-03-my-feature` from
`docs/superpowers/specs/2026-08-03-my-feature-design.md`) and run
`scripts/time-log status <topic>` — before doing anything else. See Time
tracking below for what to do with the result.
```

- [ ] **Step 4: Replace the "Time tracking:" block**

In `skills/writing-plans/SKILL.md`, find:

```markdown
**Time tracking:** This skill has one real point where it waits on your
human partner: the Subagent-Driven-vs-Inline-Execution offer in Execution
Handoff. Run `scripts/time-log pause <topic>` immediately before making
that offer, and `scripts/time-log resume <topic>` immediately after they
answer.
```

Replace with:

```markdown
**Time tracking:** The `status` call above resolves this topic's
tracking state before any other work begins.

- If it printed `JIRA: unknown` (first time this topic has been seen):
  ask "Do you want time tracked for this task?" A "no" runs
  `scripts/time-log set-jira <topic> disabled` — for the rest of this
  topic, in every phase of every skill, make zero `time-log` calls and
  skip this entire flow, with no further asking. A "yes" asks "What Jira
  ticket does this correspond to? (or say it doesn't apply)" — a ticket
  key runs `scripts/time-log set-jira <topic> <ISSUE-KEY>`; no ticket
  runs `scripts/time-log set-jira <topic> none`. Only if the result
  isn't `disabled`, now run `scripts/time-log start <topic>
  writing-plans`.
- If it printed `JIRA: disabled`: make no further `time-log` calls this
  phase at all.
- Otherwise (`JIRA: none` or an issue key, resolved by an earlier phase
  or just above): run `scripts/time-log start <topic> writing-plans` and
  continue tracking below.

Once tracking is active, this skill has one real point where it waits on
your human partner: the Subagent-Driven-vs-Inline-Execution offer in
Execution Handoff. Run `scripts/time-log pause <topic>` immediately
before making that offer, and `scripts/time-log resume <topic>`
immediately after they answer.
```

- [ ] **Step 5: Replace the entire "## Execution Handoff" section**

In `skills/writing-plans/SKILL.md`, find:

```markdown
## Execution Handoff

After saving the plan, run `scripts/time-log end <topic>`. If it fails
(exit 3 — no phase was ever started), do not silently continue: tell
your human partner "I wasn't able to track time automatically for this
phase — want to log an approximate duration manually?" If yes, ask for
the duration directly (e.g. "2h 30m") and use it in place of
`ACTIVE_HUMAN` below (use "now" in place of `STARTED_ISO`); if no, skip
the rest of this flow and go straight to offering execution choice below.
Otherwise, `time-log end` printed the phase's active duration and its
`JIRA:` field — continue below.

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

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?"**

**If Subagent-Driven chosen:**
- **REQUIRED SUB-SKILL:** Use superpowers:subagent-driven-development
- Fresh subagent per task + two-stage review

**If Inline Execution chosen:**
- **REQUIRED SUB-SKILL:** Use superpowers:executing-plans
- Batch execution with checkpoints for review
```

Replace with:

```markdown
## Execution Handoff

After saving the plan: if tracking was disabled for this topic, skip
straight to offering execution choice below — no `time-log` calls at
all. Otherwise, run `scripts/time-log pause <topic> now` (see Time
tracking above), then offer execution choice:

**"Plan complete and saved to `docs/superpowers/plans/<filename>.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?"**

If tracking is active, run `scripts/time-log resume <topic>` now that
they've answered, then run `scripts/time-log end <topic>`. If it fails
(exit 3 — no phase was ever started), do not silently continue: tell
your human partner "I wasn't able to track time automatically for this
phase — want to log an approximate duration manually?" If yes, ask for
the duration directly (e.g. "2h 30m") and use it in place of
`ACTIVE_HUMAN` below (use "now" in place of `STARTED_ISO`); if no, skip
the rest of this flow. Otherwise, `time-log end` printed the phase's
active duration and its `JIRA:` field — continue below.

- If `JIRA: none`: show the active duration (`ACTIVE_HUMAN`) to your
  human partner — nothing to publish.
- Otherwise (an issue key): resolve `cloudId` via
  `getAccessibleAtlassianResources` if not already resolved this
  conversation (ask which site if more than one), then call
  `addWorklogToJiraIssue` with that `cloudId`, `issueIdOrKey=<the issue>`,
  `timeSpent=<ACTIVE_HUMAN>`, `started=<STARTED_ISO>`, and
  `commentBody="Implementation planning: <topic>"`. Report the result —
  no confirmation prompt, the upfront answer already was the consent. If
  the Jira MCP connector isn't available, say so and continue.

Then act on their choice:

**If Subagent-Driven chosen:**
- **REQUIRED SUB-SKILL:** Use superpowers:subagent-driven-development
- Fresh subagent per task + two-stage review

**If Inline Execution chosen:**
- **REQUIRED SUB-SKILL:** Use superpowers:executing-plans
- Batch execution with checkpoints for review
```

Note the fixed ordering here: `pause` now happens **before** the offer
(a real wait point) and `end` happens **after** `resume` — the prior
text called `end` first and then tried to `pause` an already-closed
phase, which is invalid. `"time-log pause <topic> now"` (with the
trailing "now") is the exact marker Step 1's ordering test looks for —
keep that exact wording so the test can locate it.

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/claude-code/test-writing-plans-worklog.sh`
Expected: PASS (all assertions, including the ordering check).

- [ ] **Step 7: Commit**

```bash
git add skills/writing-plans/SKILL.md tests/claude-code/test-writing-plans-worklog.sh
git commit -m "feat(writing-plans): ask time-tracking once upfront, fix pause/end ordering bug, auto-publish"
```

---

### Task 4: `subagent-driven-development` — single upfront tracking prompt

**Depends on:** Task 1

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md`
- Modify: `tests/claude-code/test-sdd-worklog.sh`

**Interfaces:**
- Consumes: `time-log status|set-jira|start|pause|resume|end` from Task 1.

- [ ] **Step 1: Rewrite the content test**

Replace the entire contents of `tests/claude-code/test-sdd-worklog.sh` with:

```bash
#!/usr/bin/env bash
# Regression check: subagent-driven-development resolves time tracking
# once per plan via a single upfront question (before Task 1 dispatch),
# then every task and the final review behave automatically: no
# tracking, tracked only, or tracked with automatic Jira publish.

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

echo "=== subagent-driven-development worklog timing test ==="
echo ""

assert_contains "time-log status" "Checks resolved tracking state before Task 1 dispatch"
assert_contains "Do you want time tracked" "Asks the single upfront tracking question"
assert_contains "set-jira <topic> disabled" "Persists a decline as disabled"
assert_contains "What Jira ticket does this correspond to" "Asks for the ticket only after tracking is wanted"
assert_contains 'zero `time-log` calls' "Documents zero instrumentation when disabled"
assert_contains "no confirmation prompt" "Auto-publishes without asking each phase"
assert_contains "wasn't able to track time automatically" "Tells the human when automatic tracking failed"
assert_contains "log an approximate duration manually" "Offers a manual-duration fallback"
assert_contains "time-log pause" "Pauses around real human-wait points"
assert_contains "time-log resume" "Resumes after the human responds"
assert_contains "time-log end" "Ends the phase timer"
assert_contains "final-review" "Times the final-review phase separately"
assert_contains "addWorklogToJiraIssue" "References the Jira worklog MCP tool"
assert_not_contains "already mentioned a Jira issue key" "Old early-capture wording is gone"
assert_not_contains "Is this Jira-tracked work?" "Old per-phase-end ask is gone"

echo ""
if [[ "$failures" -ne 0 ]]; then
    echo "FAILED: $failures assertion(s)."
    exit 1
fi
echo "PASS"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-sdd-worklog.sh`
Expected: FAIL — none of the new patterns exist yet, the two `assert_not_contains` checks fail against the still-present old text.

- [ ] **Step 3: Replace the entire "## Worklog Timing" section**

In `skills/subagent-driven-development/SKILL.md`, find:

```markdown
## Worklog Timing

Derive `<topic>` from the plan filename (the slug between the date and
the rest, e.g. `2026-08-03-my-feature` from
`docs/superpowers/plans/2026-08-03-my-feature.md` — the same slug
brainstorming and writing-plans already used for this topic's spec and
plan). Run `scripts/time-log start <topic> task-N` at the same point you
record BASE for task N (Task Loop, step 1). Only Task 1's `start` call
needs to check for an already-known Jira key: if your human partner
already mentioned a Jira issue key anywhere in the conversation before
this plan's execution began (and no earlier phase captured it — this
plan may be running standalone, without a prior brainstorming or
writing-plans phase for this topic), run
`scripts/time-log set-jira <topic> <ISSUE-KEY>` right after Task 1's
`start` call. Every task after Task 1 will see it already resolved. This
skill's "continuous execution" principle means routine
dispatch/review/fix-loop activity is never a wait point — but relaying an
implementer's question to your human partner, or a plan-vs-review
conflict that needs their decision, are real waits: run
`scripts/time-log pause <topic> task-N` immediately before either, and
`scripts/time-log resume <topic> task-N` immediately after their reply.

Because Wave Dispatch (below) can have several task-N phases open at
once, always pass the phase explicitly (`task-N`) on every `pause`,
`resume`, and `end` call in this section — omitting it is only safe when
at most one phase is ever open at a time, which is true for
brainstorming and writing-plans but not here.

Run `scripts/time-log end <topic> task-N` when task N is marked complete
in the ledger (Task Loop, step 5), before appending the ledger line. If
it fails (exit 3 — this task's phase was never started, e.g. the
`time-log start` call at BASE-recording time was skipped), do not
silently continue: tell your human partner "I wasn't able to track time automatically for this task" and offer to log an approximate duration manually
(e.g. "2h 30m") to use in place of `ACTIVE_HUMAN` below (use "now" in
place of `STARTED_ISO`); if they decline, skip the rest of this flow for
this task and go straight to the ledger bookkeeping. Otherwise,
`time-log end` printed the task's active duration and its `JIRA:` field
— continue below. This same fallback applies to the final-review cycle's
`time-log end <topic> final-review` call described below.

- If `JIRA: unknown`: ask "Is this Jira-tracked work? If so, give me the
  issue key (e.g. PROJ-123)." A "no" runs
  `scripts/time-log set-jira <topic> none` and skips the rest of this
  flow — for the rest of this plan (including the final review below),
  no further prompt or publish offer. An issue key runs
  `scripts/time-log set-jira <topic> <ISSUE-KEY>` and continues below.
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
the whole-branch final review, using phase `final-review`:
`scripts/time-log start <topic> final-review` right before dispatching
the final code reviewer; `scripts/time-log pause <topic> final-review`
and `scripts/time-log resume <topic> final-review` around any wait on
your human partner; `scripts/time-log end <topic> final-review` right
after the final review is clean and any fixes are merged (before
deleting the plan's workspace), with `commentBody="Final review:
<topic>"`.
```

Replace with:

```markdown
## Worklog Timing

Derive `<topic>` from the plan filename (the slug between the date and
the rest, e.g. `2026-08-03-my-feature` from
`docs/superpowers/plans/2026-08-03-my-feature.md` — the same slug
brainstorming and writing-plans already used for this topic's spec and
plan). Before dispatching Task 1's implementer, run `scripts/time-log
status <topic>`:

- If it prints `JIRA: unknown` (this plan may be running standalone,
  without a prior brainstorming or writing-plans phase for this topic —
  or an earlier phase never resolved it): ask "Do you want time tracked
  for this plan's execution?" A "no" runs `scripts/time-log set-jira
  <topic> disabled` — for the rest of this plan (every task and the
  final review), make zero `time-log` calls and skip this entire section
  silently, with no further asking. A "yes" asks "What Jira ticket does
  this correspond to? (or say it doesn't apply)" — a ticket key runs
  `scripts/time-log set-jira <topic> <ISSUE-KEY>`; no ticket runs
  `scripts/time-log set-jira <topic> none`.
- If it prints `JIRA: disabled`: make no `time-log` calls anywhere in
  this plan's execution — proceed exactly as if this feature didn't
  exist.
- Otherwise (`JIRA: none` or an issue key, resolved here or by an
  earlier phase): tracking is active for this plan. Continue below.

Only Task 1 needs to do this resolution — every task after it (and the
final-review cycle) sees the state already resolved via `status` and
skips straight to whichever branch applies, with no further asking.

If tracking is active, run `scripts/time-log start <topic> task-N` at
the same point you record BASE for task N (Task Loop, step 1). This
skill's "continuous execution" principle means routine
dispatch/review/fix-loop activity is never a wait point — but relaying an
implementer's question to your human partner, or a plan-vs-review
conflict that needs their decision, are real waits: run
`scripts/time-log pause <topic> task-N` immediately before either, and
`scripts/time-log resume <topic> task-N` immediately after their reply.

Because Wave Dispatch (below) can have several task-N phases open at
once, always pass the phase explicitly (`task-N`) on every `pause`,
`resume`, and `end` call in this section — omitting it is only safe when
at most one phase is ever open at a time, which is true for
brainstorming and writing-plans but not here.

Run `scripts/time-log end <topic> task-N` when task N is marked complete
in the ledger (Task Loop, step 5), before appending the ledger line. If
it fails (exit 3 — this task's phase was never started, e.g. the
`time-log start` call at BASE-recording time was skipped), do not
silently continue: tell your human partner "I wasn't able to track time automatically for this task" and offer to log an approximate duration manually
(e.g. "2h 30m") to use in place of `ACTIVE_HUMAN` below (use "now" in
place of `STARTED_ISO`); if they decline, skip the rest of this flow for
this task and go straight to the ledger bookkeeping. Otherwise,
`time-log end` printed the task's active duration and its `JIRA:` field
— continue below. This same fallback applies to the final-review cycle's
`time-log end <topic> final-review` call described below.

- If `JIRA: none`: show the active duration (`ACTIVE_HUMAN`) to your
  human partner, then go straight to the ledger bookkeeping — nothing to
  publish.
- Otherwise (an issue key): resolve `cloudId` via
  `getAccessibleAtlassianResources` if not already resolved this
  conversation (ask which site if more than one), then call
  `addWorklogToJiraIssue` with that `cloudId`, `issueIdOrKey=<the
  issue>`, `timeSpent=<ACTIVE_HUMAN>`, `started=<STARTED_ISO>`, and
  `commentBody="Task N: <task title>"`. Report the result — no
  confirmation prompt, the upfront answer already was the consent. If
  the Jira MCP connector isn't available, say so and continue.

If tracking is active, run the same `start`/pause-resume/`end`/publish
cycle once more around the whole-branch final review, using phase
`final-review`: `scripts/time-log start <topic> final-review` right
before dispatching the final code reviewer; `scripts/time-log pause
<topic> final-review` and `scripts/time-log resume <topic>
final-review` around any wait on your human partner; `scripts/time-log
end <topic> final-review` right after the final review is clean and any
fixes are merged (before deleting the plan's workspace), with
`commentBody="Final review: <topic>"`.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/claude-code/test-sdd-worklog.sh`
Expected: PASS (all assertions).

- [ ] **Step 5: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md tests/claude-code/test-sdd-worklog.sh
git commit -m "feat(subagent-driven-development): ask time-tracking once upfront at Task 1, auto-publish"
```

---

## Post-plan note (not a task — informational)

Tasks 2, 3, and 4 each modify only their own skill's `SKILL.md` and their
own dedicated test file — no shared file like the earlier plans'
`run-skill-tests.sh` array is touched here, so no merge conflict is
expected even if these three tasks run in the same parallel wave.
