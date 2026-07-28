# Parallel Planning and Execution — Design

**Status:** Approved by user, fork-local change (not intended for upstream PR).

## Goal

Speed up both the planning phase (`brainstorming`, `writing-plans`) and the
execution phase (`subagent-driven-development`) by dispatching subagents in
parallel wherever tasks are genuinely independent, while keeping resource
usage proportional to actual independent work — not parallelizing trivial,
single-item cases.

## Motivation

The current skills already support parallel dispatch for independent
*investigations* (`dispatching-parallel-agents`), but:

- `brainstorming`'s "Explore project context" step and `writing-plans`'s
  File Structure mapping step both investigate the codebase serially in the
  main session.
- `subagent-driven-development` explicitly forbids parallel implementers
  ("Never dispatch multiple implementation subagents in parallel
  (conflicts)") because all implementers share one working tree.

This design removes both serialization points without discarding the
existing correctness machinery (ledger, task review, fix loop, final
review).

## Scope decision

This is a fork-local change, not a candidate for upstream PR. The strict
PR/eval requirements in this repo's `CLAUDE.md` do not apply. The
modifications below edit the existing skills in place rather than creating
parallel "parallel-*" variants — there is one flow, and it is parallel by
default where it can be.

Target must work across harnesses. Where the `Workflow` tool (with
`isolation: 'worktree'`) is available, execution can lean on it for
automatic per-task worktree isolation; where it isn't, the same result is
achieved with manual `git worktree` commands. Both paths are specified so
neither harness is left behind.

## Section 1: Parallel exploration in `brainstorming`

Step 1 ("Explore project context") changes from a single serial
investigation to a mechanically-decided fan-out:

1. Before exploring, list concrete investigation items needed to understand
   the idea's context — e.g. "the module that would host this", "an
   existing similar feature", "test conventions in this area", "relevant
   prior specs/decisions". This list is independent of how the idea itself
   is scoped (a single-feature ticket routinely requires understanding
   several existing parts of the system to implement).
2. **Decision rule (mechanical, not judgment-based):**
   - If the list has **2+ items that live in different parts of the
     codebase and don't depend on each other's findings**, dispatch one
     `Explore` (or `general-purpose`) subagent per item, all in the same
     message (parallel).
   - If the list **collapses to 1 item** (or one item's investigation
     requires the result of another), investigate directly — no subagent
     dispatch. Overhead of coordinating agents isn't worth it for a single
     thing to look at.
3. Synthesize all subagent findings before starting the one-at-a-time
   clarifying questions.

This rule is unchanged in spirit from `dispatching-parallel-agents`, just
applied specifically at brainstorming's exploration step.

## Section 2: Parallel exploration in `writing-plans` (File Structure step)

Same mechanical rule, applied to the File Structure mapping step, before
defining tasks:

- List concrete items needed to decide the file structure (e.g. "how
  module X is structured today", "what pattern similar files follow",
  "what interfaces subsystem Y exposes that this plan will consume").
- 2+ independent items → one explorer per item, parallel, then synthesize
  and decide the file structure.
- 1 item, or already covered during brainstorming → investigate directly.

## Section 3: Plan format — `Depends on` field

Every task in the plan template gains a required field:

```markdown
### Task N: [Component Name]

**Depends on:** Task 2, Task 3
```

or `**Depends on:** None`.

Rules:

- `None` means the task is eligible for the first wave of parallel
  dispatch.
- Must be consistent with the existing **Interfaces** section: if Task 5
  "Consumes" something Task 2 "Produces", Task 5 must list
  `Depends on: Task 2`.
- Added to `writing-plans`'s self-review checklist (alongside the existing
  Type Consistency check): verify `Depends on` matches what Interfaces
  implies.

## Section 4: Parallel execution in `subagent-driven-development`

### Dependency graph

At setup, after reading the plan, the controller builds a dependency graph
from each task's `Depends on` field (in addition to the existing ledger
check for already-completed tasks).

### Wave loop

Replaces the single "dispatch implementer → review → next task" loop with:

1. Compute the set of **ready** tasks: not yet complete, all `Depends on`
   entries already complete.
2. Take up to **4** of them as the current wave (concurrency cap — larger
   ready-sets queue into later waves).
3. For each task in the wave:
   - **Wave size 1:** unchanged current behavior — dispatch directly in the
     plan's working tree, no worktree overhead.
   - **Wave size 2+:**
     - **If the `Workflow` tool is available (Claude Code):** delegate the
       wave to a `Workflow` script using `isolation: 'worktree'`,
       `pipeline()`-ing implementer → task review (and fix loop, scoped
       re-review) per task, so each task's isolation and merge-back is
       handled by the tool.
     - **Else (other harnesses):** the controller creates one git worktree
       per task directly — `git worktree add
       <plan-workspace>/tasks/task-N -b sdd/<plan>/task-N` branched from
       the plan branch's current HEAD, inside the already-isolated
       plan workspace managed by `scripts/sdd-workspace`. This is a
       controller-internal step, not a call into
       `using-git-worktrees` (that skill's consent/detection flow is
       plan-level, not per-task).
4. Each implementer runs its normal cycle (implement, test, commit,
   self-review) inside its worktree.
5. Task review works unchanged — the reviewer only reads a diff file
   (`review-package` output), so reviews for multiple wave tasks can also
   dispatch in parallel without conflict, worktree or not.
6. Fix loops (per task) proceed independently in parallel too — each lives
   in its own worktree.
7. **As soon as a task's review is clean** (including any fix-loop
   rounds), the controller merges its worktree branch into the plan branch
   immediately — sequential merges, one at a time, in completion order —
   deletes that task's worktree, and appends the ledger entry. Faster
   tasks do not wait for the whole wave to finish before integrating.
8. If a merge conflicts (should be rare if dependencies were declared
   correctly — signals a missed dependency), the controller resolves it if
   trivial, otherwise escalates to the human partner.
9. Once all wave tasks are merged, recompute the ready set and open the
   next wave.

### What stays unchanged

- The final whole-branch review remains a single sequential pass at the
  end — no benefit to parallelizing a review of one complete diff.
- Model selection guidance (cheap/standard/most-capable by task
  complexity) applies per task exactly as before, independent of wave
  size.
- The ledger is written only by the controller, never by subagents. Even
  with parallel implementers, their reports return to the controller
  (individually or via `Workflow`'s aggregated result) and the controller
  appends ledger entries in order — no write race.
- `Never dispatch multiple implementation subagents in parallel` is
  replaced by the wave logic above — parallelism is now scoped to
  worktree-isolated, dependency-cleared tasks only.

## Section 5: `dispatching-parallel-agents`

Unchanged. Remains the general-purpose reference for "N tool calls in one
message = parallel dispatch"; the other skills cite it rather than
duplicating its content.

## Out of scope

- No change to `finishing-a-development-branch`, `executing-plans`
  (parallel-session path stays serial — it's explicitly the
  fallback for when subagents aren't available), or review-content
  skills (`requesting-code-review`, `receiving-code-review`).
- No new skill files — all changes land in the four skills named above.
