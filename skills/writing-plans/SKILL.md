---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

## Overview

Write comprehensive implementation plans assuming the engineer has zero context for our codebase and questionable taste. Document everything they need to know: which files to touch for each task, code, testing, docs they might need to check, how to test it. Give them the whole plan as bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume they are a skilled developer, but know almost nothing about our toolset or problem domain. Assume they don't know good test design very well.

**Announce at start:** "I'm using the writing-plans skill to create the
implementation plan." Immediately after announcing, derive `<topic>`
from the spec filename you were given (the slug between the date and
`-design`, e.g. `2026-08-03-my-feature` from
`docs/superpowers/specs/2026-08-03-my-feature-design.md`) and run
`scripts/time-log status <topic>` — before doing anything else. See Time
tracking below for what to do with the result.

**Context:** If working in an isolated worktree, it should have been created via the `superpowers:using-git-worktrees` skill at execution time.

**Save plans to:** `docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md`
- (User preferences for plan location override this default)

**Time tracking:** The `status` call above resolves this topic's
tracking state before any other work begins.

- If it printed `JIRA: unknown` (first time this topic has been seen):
  ask "Do you want time tracked for this task?" A "no" runs
  `scripts/time-log set-jira <topic> disabled` — for the rest of this
  topic, in every phase of every skill, make zero `time-log` calls and
  skip this entire flow, with no further asking. A "yes" asks
  "What Jira ticket does this correspond to? (or say it doesn't apply)"
  — a ticket key runs `scripts/time-log set-jira <topic> <ISSUE-KEY>`;
  no ticket runs `scripts/time-log set-jira <topic> none`. Only if the result
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

## Scope Check

If the spec covers multiple independent subsystems, it should have been broken into sub-project specs during brainstorming. If it wasn't, suggest breaking this into separate plans — one per subsystem. Each plan should produce working, testable software on its own.

## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.

**Parallel exploration:** before mapping file structure, list the concrete
items you need to understand first — e.g. "how module X is structured
today", "what pattern similar files follow", "what interfaces subsystem Y
exposes that this plan will consume". This is a mechanical count, not a
judgment call:

- If the list has **2+ items that live in different parts of the codebase
  and don't depend on each other's findings**, dispatch one Explore (or
  general-purpose) subagent per item, all in the same message (parallel),
  then synthesize before deciding the file structure.
- If the list **collapses to 1 item** — or investigating one item requires
  the result of another — investigate directly. Coordinating a subagent
  for a single thing to look at isn't worth the overhead.

- Design units with clear boundaries and well-defined interfaces. Each file should have one clear responsibility.
- You reason best about code you can hold in context at once, and your edits are more reliable when files are focused. Prefer smaller, focused files over large ones that do too much.
- Files that change together should live together. Split by responsibility, not by technical layer.
- In existing codebases, follow established patterns. If the codebase uses large files, don't unilaterally restructure - but if a file you're modifying has grown unwieldy, including a split in the plan is reasonable.

This structure informs the task decomposition. Each task should produce self-contained changes that make sense independently.

## Task Right-Sizing

A task is the smallest unit that carries its own test cycle and is worth a
fresh reviewer's gate. When drawing task boundaries: fold setup,
configuration, scaffolding, and documentation steps into the task whose
deliverable needs them; split only where a reviewer could meaningfully
reject one task while approving its neighbor. Each task ends with an
independently testable deliverable.

## Task Dependencies

Every task declares `**Depends on:** Task N, Task M` (or `None`) directly
under its heading. This is not documentation flavor — `subagent-driven-development`
reads this field to compute which tasks can dispatch together in a
parallel wave. Keep it consistent with the task's **Interfaces** block: if
Task 5 Consumes something Task 2 Produces, Task 5 must list `Depends on:
Task 2`. A task with no unmet dependency in the plan lists `None`.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

## Global Constraints

[The spec's project-wide requirements — version floors, dependency limits,
naming and copy rules, platform requirements — one line each, with exact
values copied verbatim from the spec. Every task's requirements implicitly
include this section.]

---
```

## Task Structure

````markdown
### Task N: [Component Name]

**Depends on:** Task 2, Task 3 (or `None` if this task can start immediately)

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

**Interfaces:**
- Consumes: [what this task uses from earlier tasks — exact signatures]
- Produces: [what later tasks rely on — exact function names, parameter
  and return types. A task's implementer sees only their own task; this
  block is how they learn the names and types neighboring tasks use.]

- [ ] **Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
````

## No Placeholders

Every step must contain the actual content an engineer needs. These are **plan failures** — never write them:
- "TBD", "TODO", "implement later", "fill in details"
- "Add appropriate error handling" / "add validation" / "handle edge cases"
- "Write tests for the above" (without actual test code)
- "Similar to Task N" (repeat the code — the engineer may be reading tasks out of order)
- Steps that describe what to do without showing how (code blocks required for code steps)
- References to types, functions, or methods not defined in any task

## Self-Review

After writing the complete plan, look at the spec with fresh eyes and check the plan against it. This is a checklist you run yourself — not a subagent dispatch.

**1. Spec coverage:** Skim each section/requirement in the spec. Can you point to a task that implements it? List any gaps.

**2. Placeholder scan:** Search your plan for red flags — any of the patterns from the "No Placeholders" section above. Fix them.

**3. Type consistency:** Do the types, method signatures, and property names you used in later tasks match what you defined in earlier tasks? A function called `clearLayers()` in Task 3 but `clearFullLayers()` in Task 7 is a bug.

**4. Depends-on consistency:** Does every task have a `Depends on` field? Does it match what the task's Interfaces block Consumes from earlier tasks — no task lists `None` while its Interfaces block consumes something another task Produces, and no task lists a dependency it doesn't actually need.

If you find issues, fix them inline. No need to re-review — just fix and move on. If you find a spec requirement with no task, add the task.

## Execution Handoff

After saving the plan: if tracking was disabled for this topic, skip
straight to offering execution choice below — no `time-log` calls at
all. Otherwise, run `scripts/time-log pause <topic>` now (see Time
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
