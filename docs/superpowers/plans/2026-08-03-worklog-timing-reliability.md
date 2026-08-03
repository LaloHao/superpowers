# Worklog Timing Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three reliability gaps in the Jira worklog timing feature found in production: `time-log start` not living at an enforced entry point, silent failure when `time-log end` has no phase to close, and no early capture of a Jira key volunteered before the end-of-phase prompt.

**Architecture:** Doc-only edits to the same three skills the timing feature already touches (`brainstorming`, `writing-plans`, `subagent-driven-development`). No changes to `scripts/time-log` itself — only to when/how each skill calls it, and what each skill does when a call fails.

**Tech Stack:** Markdown skill files, existing bash content-test pattern (`tests/claude-code/test-*-worklog.sh`, extended with new assertions rather than new files).

## Global Constraints

- Fork-local change — no upstream PR process, no eval-evidence requirement.
- `scripts/time-log`'s behavior (subcommands, exit codes) is unchanged by this plan.
- **Deviation from the design spec, noted here per writing-plans' self-review process:** the spec's Section 1 said to move `time-log start` to "immediately after Announce at start" for both `writing-plans` and `subagent-driven-development`. On inspection, `subagent-driven-development/SKILL.md` has no "Announce at start" line at all (only `writing-plans` and `executing-plans` do) — its `time-log start <topic> task-N` call is already anchored to a concrete, already-enforced action ("the same point you record BASE for task N," Task Loop step 1), which is exactly the kind of enforced anchor Section 1 is meant to create. So Task 3 below implements Section 2 (fallback) and Section 3 (early capture) for `subagent-driven-development`, but does **not** apply Section 1 — there is nothing to move it to, and the existing anchor already satisfies the spec's intent.
- Every `time-log end` call across all three skills gets the same fallback shape: on exit 3 (no phase open), tell the human partner tracking wasn't captured automatically, offer to log an approximate duration manually, and use that in place of `ACTIVE_HUMAN` (with "now" standing in for `STARTED_ISO`) for the rest of that phase's publish flow if they provide one.
- Early Jira-key capture (`set-jira` called right after `start`, without waiting for end-of-phase) applies to all three skills' entry points.

---

### Task 1: `brainstorming` — enforced start, early capture, end-of-phase fallback

**Depends on:** None

**Files:**
- Modify: `skills/brainstorming/SKILL.md`
- Modify: `tests/claude-code/test-brainstorming-worklog.sh` (add assertions, existing file from the prior worklog-timing plan)

**Interfaces:**
- Consumes: `scripts/time-log start|pause|resume|end|set-jira` (unchanged CLI from the prior plan).
- Produces: none — this is the last consumer of the CLI on this topic.

- [ ] **Step 1: Extend the failing content test**

In `tests/claude-code/test-brainstorming-worklog.sh`, find:

```bash
assert_contains "time-log start" "Starts the phase timer"
```

Replace with:

```bash
assert_contains "Start time tracking and explore project context" "Checklist item 1 starts time tracking, not a loose paragraph"
assert_contains "time-log start" "Starts the phase timer"
assert_contains "already mentioned a Jira issue key" "Captures an already-given Jira key immediately after start"
assert_contains "wasn't able to track time automatically" "Tells the human when automatic tracking failed"
assert_contains "log an approximate duration manually" "Offers a manual-duration fallback"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-brainstorming-worklog.sh`
Expected: FAIL — the three new patterns don't exist in `skills/brainstorming/SKILL.md` yet (the two pre-existing assertions still pass).

- [ ] **Step 3: Move `time-log start` into checklist item 1**

In `skills/brainstorming/SKILL.md`, find:

```markdown
1. **Explore project context** — check files, docs, recent commits
```

Replace with:

```markdown
1. **Start time tracking and explore project context** — run `scripts/time-log start <topic> brainstorming` as soon as you have a working topic slug, then check files, docs, recent commits
```

- [ ] **Step 4: Rewrite the "Time tracking" paragraph — remove the duplicate start instruction, add early Jira-key capture**

In `skills/brainstorming/SKILL.md`, find:

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
```

Replace with:

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

- [ ] **Step 5: Add the end-of-phase fallback**

In `skills/brainstorming/SKILL.md`, find:

```markdown
**Time tracking and Jira publish:**

Before invoking writing-plans, run `scripts/time-log end <topic>` — this
prints the phase's active duration and its `JIRA:` field.

- If `JIRA: unknown`: ask "Is this Jira-tracked work? If so, give me the
```

Replace with:

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
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/claude-code/test-brainstorming-worklog.sh`
Expected: PASS (all assertions, old and new).

- [ ] **Step 7: Commit**

```bash
git add skills/brainstorming/SKILL.md tests/claude-code/test-brainstorming-worklog.sh
git commit -m "fix(brainstorming): enforce time-tracking start, capture early Jira key, handle tracking failure"
```

---

### Task 2: `writing-plans` — enforced start, early capture, end-of-phase fallback

**Depends on:** None

**Files:**
- Modify: `skills/writing-plans/SKILL.md`
- Modify: `tests/claude-code/test-writing-plans-worklog.sh` (add assertions, existing file from the prior worklog-timing plan)

**Interfaces:**
- Consumes: `scripts/time-log start|pause|resume|end|set-jira` (unchanged CLI from the prior plan).

- [ ] **Step 1: Extend the failing content test**

In `tests/claude-code/test-writing-plans-worklog.sh`, find:

```bash
assert_contains "time-log start" "Starts the phase timer"
```

Replace with:

```bash
assert_contains "time-log start" "Starts the phase timer"
assert_contains "already mentioned a Jira issue key" "Captures an already-given Jira key immediately after start"
assert_contains "wasn't able to track time automatically" "Tells the human when automatic tracking failed"
assert_contains "log an approximate duration manually" "Offers a manual-duration fallback"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-writing-plans-worklog.sh`
Expected: FAIL — the two new patterns don't exist in `skills/writing-plans/SKILL.md` yet (the pre-existing assertions still pass).

- [ ] **Step 3: Move `time-log start` to immediately after Announce at start, add early Jira-key capture**

In `skills/writing-plans/SKILL.md`, find:

```markdown
**Announce at start:** "I'm using the writing-plans skill to create the implementation plan."

**Context:** If working in an isolated worktree, it should have been created via the `superpowers:using-git-worktrees` skill at execution time.

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
```

Replace with:

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

**Context:** If working in an isolated worktree, it should have been created via the `superpowers:using-git-worktrees` skill at execution time.

**Save plans to:** `docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md`
- (User preferences for plan location override this default)

**Time tracking:** This skill has one real point where it waits on your
human partner: the Subagent-Driven-vs-Inline-Execution offer in Execution
Handoff. Run `scripts/time-log pause <topic>` immediately before making
that offer, and `scripts/time-log resume <topic>` immediately after they
answer.
```

- [ ] **Step 4: Add the end-of-phase fallback**

In `skills/writing-plans/SKILL.md`, find:

```markdown
## Execution Handoff

After saving the plan, run `scripts/time-log end <topic>` — this prints
the phase's active duration and its `JIRA:` field.

- If `JIRA: unknown`: ask "Is this Jira-tracked work? If so, give me the
```

Replace with:

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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/claude-code/test-writing-plans-worklog.sh`
Expected: PASS (all assertions, old and new).

- [ ] **Step 6: Commit**

```bash
git add skills/writing-plans/SKILL.md tests/claude-code/test-writing-plans-worklog.sh
git commit -m "fix(writing-plans): enforce time-tracking start, capture early Jira key, handle tracking failure"
```

---

### Task 3: `subagent-driven-development` — early capture, per-task and final-review fallback

**Depends on:** None

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md`
- Modify: `tests/claude-code/test-sdd-worklog.sh` (add assertions, existing file from the prior worklog-timing plan)

**Interfaces:**
- Consumes: `scripts/time-log start|pause|resume|end|set-jira` (unchanged CLI from the prior plan).

**Note:** unlike Tasks 1 and 2, this task does not move `time-log start` to a new anchor — see this plan's Global Constraints for why (`subagent-driven-development` has no "Announce at start" line; its existing anchor, "the same point you record BASE for task N," already satisfies the spec's intent).

- [ ] **Step 1: Extend the failing content test**

In `tests/claude-code/test-sdd-worklog.sh`, find:

```bash
assert_contains "time-log start" "Starts a phase timer per task"
```

Replace with:

```bash
assert_contains "time-log start" "Starts a phase timer per task"
assert_contains "already mentioned a Jira issue key" "Falls back to Task 1's start point for an already-given Jira key"
assert_contains "wasn't able to track time automatically" "Tells the human when automatic tracking failed"
assert_contains "log an approximate duration manually" "Offers a manual-duration fallback"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-sdd-worklog.sh`
Expected: FAIL — the three new patterns don't exist in `skills/subagent-driven-development/SKILL.md` yet (the pre-existing assertions still pass).

- [ ] **Step 3: Add early Jira-key capture at Task 1's `time-log start`**

In `skills/subagent-driven-development/SKILL.md`, find:

```markdown
Derive `<topic>` from the plan filename (the slug between the date and
the rest, e.g. `2026-08-03-my-feature` from
`docs/superpowers/plans/2026-08-03-my-feature.md` — the same slug
brainstorming and writing-plans already used for this topic's spec and
plan). Run `scripts/time-log start <topic> task-N` at the same point you
record BASE for task N (Task Loop, step 1). This skill's "continuous
execution" principle means routine dispatch/review/fix-loop activity is
never a wait point — but relaying an implementer's question to your human
partner, or a plan-vs-review conflict that needs their decision, are real
waits: run `scripts/time-log pause <topic> task-N` immediately before
either, and `scripts/time-log resume <topic> task-N` immediately after
their reply.
```

Replace with:

```markdown
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
```

- [ ] **Step 4: Add the per-task end-of-phase fallback**

In `skills/subagent-driven-development/SKILL.md`, find:

```markdown
Run `scripts/time-log end <topic> task-N` when task N is marked complete
in the ledger (Task Loop, step 5), before appending the ledger line.
This prints the task's active duration and its `JIRA:` field.

- If `JIRA: unknown`: ask "Is this Jira-tracked work? If so, give me the
```

Replace with:

```markdown
Run `scripts/time-log end <topic> task-N` when task N is marked complete
in the ledger (Task Loop, step 5), before appending the ledger line. If
it fails (exit 3 — this task's phase was never started, e.g. the
`time-log start` call at BASE-recording time was skipped), do not
silently continue: tell your human partner tracking wasn't captured
automatically for this task and offer to log an approximate duration
manually (e.g. "2h 30m") to use in place of `ACTIVE_HUMAN` below (use
"now" in place of `STARTED_ISO`); if they decline, skip the rest of this
flow for this task and go straight to the ledger bookkeeping. Otherwise,
`time-log end` printed the task's active duration and its `JIRA:` field
— continue below. This same fallback applies to the final-review cycle's
`time-log end <topic> final-review` call described below.

- If `JIRA: unknown`: ask "Is this Jira-tracked work? If so, give me the
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/claude-code/test-sdd-worklog.sh`
Expected: PASS (all assertions, old and new).

- [ ] **Step 6: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md tests/claude-code/test-sdd-worklog.sh
git commit -m "fix(subagent-driven-development): capture early Jira key, handle per-task tracking failure"
```

---

## Post-plan note (not a task — informational)

All three tasks are independent (different files, `Depends on: None`),
so they can dispatch in the same parallel wave. None of them touch
`tests/claude-code/run-skill-tests.sh` (no new test files are created,
only existing ones extended), so — unlike the prior worklog-timing plan
— there is no expected merge conflict on that shared array this time.
