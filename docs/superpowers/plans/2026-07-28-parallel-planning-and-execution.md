# Parallel Planning and Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `brainstorming` and `writing-plans` fan out codebase exploration to parallel subagents when there are 2+ independent things to look at, and make `subagent-driven-development` dispatch independent plan tasks in parallel waves using per-task git worktrees, instead of serializing everything.

**Architecture:** Two doc-only skill edits add a mechanical "count independent investigation items" rule to `brainstorming` and `writing-plans`'s exploration steps. A new `scripts/task-worktree` script (add/remove) gives `subagent-driven-development` a way to isolate each task in a wave in its own worktree. `subagent-driven-development`'s SKILL.md is then rewritten to compute a dependency graph from a new `Depends on` plan field, dispatch up to 4 ready tasks per wave (worktree-isolated when wave size ≥ 2, using the `Workflow` tool when available or `task-worktree` otherwise), and merge each task into the plan branch as soon as its review clears.

**Tech Stack:** Bash (POSIX-ish, `set -euo pipefail`, matching existing `skills/subagent-driven-development/scripts/*`), Markdown skill files, existing bash test-harness pattern (`tests/claude-code/test-*.sh` with `pass`/`fail`/`assert_contains` helpers).

## Global Constraints

- Fork-local change — no upstream PR process, no eval-evidence requirement, but still follow existing repo script/test conventions exactly (shebang, `set -euo pipefail`, exit code conventions: `2` for usage/missing-input errors, `3` for "not found"-type semantic errors).
- Parallel dispatch only happens for tasks the plan explicitly marks independent via the `Depends on` field — no inference from prose.
- Concurrency cap: **max 4** implementers dispatched per wave.
- Per-task worktrees live at `<sdd-workspace>/tasks/task-<N>` on branch `sdd/<plan-slug>/task-<N>`, where `<sdd-workspace>` is `scripts/sdd-workspace PLAN_FILE`'s output (already self-ignored via its `.gitignore`).
- Merges from task worktrees into the plan branch happen **sequentially, immediately** when each task's review clears — never batched until the whole wave finishes.
- When wave size is 1, behavior is unchanged from today (no worktree, direct dispatch in the plan's working tree).
- The `Workflow` tool path is used only when available in the harness (Claude Code); the manual `task-worktree` path is the universal fallback and must work standalone.

---

### Task 1: `writing-plans` — `Depends on` field and parallel File Structure exploration

**Files:**
- Modify: `skills/writing-plans/SKILL.md`
- Test: `tests/claude-code/test-writing-plans-parallel.sh`
- Modify: `tests/claude-code/run-skill-tests.sh:76-80` (register new test)

**Interfaces:**
- Produces: the `Depends on` field convention that Task 4's `subagent-driven-development` rewrite reads to build its dependency graph. Format: `**Depends on:** Task 2, Task 3` or `**Depends on:** None`, placed directly under the task heading, before **Files**.

- [ ] **Step 1: Write the failing content test**

Create `tests/claude-code/test-writing-plans-parallel.sh`:

```bash
#!/usr/bin/env bash
# Regression check: writing-plans requires a Depends-on field per task and
# fans out File Structure exploration to parallel subagents when there are
# 2+ independent things to investigate.

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

echo "=== writing-plans parallel exploration test ==="
echo ""

assert_contains "**Depends on:**" "Task Structure includes a Depends on field"
assert_contains "Depends on" "Depends-on field mentioned outside just the template"
assert_contains "2+ items" "Mechanical rule: 2+ independent items triggers parallel dispatch"
assert_contains "collapses to 1 item" "Mechanical rule: 1 item means no subagent dispatch"

echo ""
if [[ "$failures" -ne 0 ]]; then
    echo "FAILED: $failures assertion(s)."
    exit 1
fi
echo "PASS"
```

Make it executable: `chmod +x tests/claude-code/test-writing-plans-parallel.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-writing-plans-parallel.sh`
Expected: FAIL — none of the four patterns exist in `skills/writing-plans/SKILL.md` yet.

- [ ] **Step 3: Add the `Depends on` field to the Task Structure template**

In `skills/writing-plans/SKILL.md`, find this block under `## Task Structure`:

```markdown
````markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
```

Replace it with:

```markdown
````markdown
### Task N: [Component Name]

**Depends on:** Task 2, Task 3 (or `None` if this task can start immediately)

**Files:**
- Create: `exact/path/to/file.py`
```

- [ ] **Step 4: Add a "Task Dependencies" section explaining the field**

Immediately after the `## Task Right-Sizing` section (before `## Bite-Sized Task Granularity`), insert:

```markdown
## Task Dependencies

Every task declares `**Depends on:** Task N, Task M` (or `None`) directly
under its heading. This is not documentation flavor — `subagent-driven-development`
reads this field to compute which tasks can dispatch together in a
parallel wave. Keep it consistent with the task's **Interfaces** block: if
Task 5 Consumes something Task 2 Produces, Task 5 must list `Depends on:
Task 2`. A task with no unmet dependency in the plan lists `None`.
```

- [ ] **Step 5: Add the parallel exploration rule to File Structure**

In `skills/writing-plans/SKILL.md`, find the `## File Structure` section:

```markdown
## File Structure

Before defining tasks, map out which files will be created or modified and what each one is responsible for. This is where decomposition decisions get locked in.
```

Replace with:

```markdown
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
```

- [ ] **Step 6: Add the Depends-on consistency check to Self-Review**

In `skills/writing-plans/SKILL.md`, find:

```markdown
**3. Type consistency:** Do the types, method signatures, and property names you used in later tasks match what you defined in earlier tasks? A function called `clearLayers()` in Task 3 but `clearFullLayers()` in Task 7 is a bug.
```

Replace with:

```markdown
**3. Type consistency:** Do the types, method signatures, and property names you used in later tasks match what you defined in earlier tasks? A function called `clearLayers()` in Task 3 but `clearFullLayers()` in Task 7 is a bug.

**4. Depends-on consistency:** Does every task have a `Depends on` field? Does it match what the task's Interfaces block Consumes from earlier tasks — no task lists `None` while its Interfaces block consumes something another task Produces, and no task lists a dependency it doesn't actually need.
```

- [ ] **Step 7: Register the new test in the runner**

In `tests/claude-code/run-skill-tests.sh`, find:

```bash
tests=(
    "test-worktree-path-policy.sh"
    "test-sdd-workspace.sh"
    "test-subagent-driven-development.sh"
)
```

Replace with:

```bash
tests=(
    "test-worktree-path-policy.sh"
    "test-sdd-workspace.sh"
    "test-subagent-driven-development.sh"
    "test-writing-plans-parallel.sh"
)
```

- [ ] **Step 8: Run test to verify it passes**

Run: `bash tests/claude-code/test-writing-plans-parallel.sh`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add skills/writing-plans/SKILL.md tests/claude-code/test-writing-plans-parallel.sh tests/claude-code/run-skill-tests.sh
git commit -m "feat(writing-plans): add Depends-on field and parallel File Structure exploration"
```

---

### Task 2: `brainstorming` — parallel exploration in "Explore project context"

**Files:**
- Modify: `skills/brainstorming/SKILL.md`
- Test: `tests/claude-code/test-brainstorming-parallel.sh`
- Modify: `tests/claude-code/run-skill-tests.sh` (register new test)

**Interfaces:**
- Consumes: none (independent of Task 1 — different skill file).
- Produces: the same mechanical "2+ independent items → parallel, 1 item → direct" rule text pattern established in Task 1, applied to brainstorming's own exploration step, for consistency across both skills.

- [ ] **Step 1: Write the failing content test**

Create `tests/claude-code/test-brainstorming-parallel.sh`:

```bash
#!/usr/bin/env bash
# Regression check: brainstorming fans out "Explore project context" to
# parallel subagents when there are 2+ independent things to investigate.

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

echo "=== brainstorming parallel exploration test ==="
echo ""

assert_contains "2+ items" "Mechanical rule: 2+ independent items triggers parallel dispatch"
assert_contains "collapses to 1 item" "Mechanical rule: 1 item means no subagent dispatch"
assert_contains "Explore project context" "Original checklist item preserved"

echo ""
if [[ "$failures" -ne 0 ]]; then
    echo "FAILED: $failures assertion(s)."
    exit 1
fi
echo "PASS"
```

Make it executable: `chmod +x tests/claude-code/test-brainstorming-parallel.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-brainstorming-parallel.sh`
Expected: FAIL — the two mechanical-rule patterns don't exist yet (the third, "Explore project context", already exists in the checklist and passes).

- [ ] **Step 3: Add the parallel exploration rule to the Process section**

In `skills/brainstorming/SKILL.md`, find in "**Understanding the idea:**":

```markdown
**Understanding the idea:**

- Check out the current project state first (files, docs, recent commits)
- Before asking detailed questions, assess scope: if the request describes multiple independent subsystems (e.g., "build a platform with chat, file storage, billing, and analytics"), flag this immediately. Don't spend questions refining details of a project that needs to be decomposed first.
```

Replace with:

```markdown
**Understanding the idea:**

- Check out the current project state first (files, docs, recent commits).
  List the concrete items you need to look at — e.g. "the module that
  would host this", "an existing similar feature", "test conventions in
  this area", "relevant prior specs/decisions". This is independent of how
  the idea itself is scoped: even a single-feature request routinely
  requires understanding several existing parts of the system. Decide
  mechanically, not by feel:
  - **2+ items that live in different parts of the codebase and don't
    depend on each other's findings** → dispatch one Explore (or
    general-purpose) subagent per item, all in the same message
    (parallel), then synthesize before asking clarifying questions.
  - **Collapses to 1 item** (or one item needs another's result first) →
    investigate directly, no subagent dispatch.
- Before asking detailed questions, assess scope: if the request describes multiple independent subsystems (e.g., "build a platform with chat, file storage, billing, and analytics"), flag this immediately. Don't spend questions refining details of a project that needs to be decomposed first.
```

- [ ] **Step 4: Register the new test in the runner**

In `tests/claude-code/run-skill-tests.sh`, find (after Task 1's edit):

```bash
tests=(
    "test-worktree-path-policy.sh"
    "test-sdd-workspace.sh"
    "test-subagent-driven-development.sh"
    "test-writing-plans-parallel.sh"
)
```

Replace with:

```bash
tests=(
    "test-worktree-path-policy.sh"
    "test-sdd-workspace.sh"
    "test-subagent-driven-development.sh"
    "test-writing-plans-parallel.sh"
    "test-brainstorming-parallel.sh"
)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/claude-code/test-brainstorming-parallel.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add skills/brainstorming/SKILL.md tests/claude-code/test-brainstorming-parallel.sh tests/claude-code/run-skill-tests.sh
git commit -m "feat(brainstorming): add parallel project-context exploration rule"
```

---

### Task 3: `scripts/task-worktree` — per-task worktree add/remove

**Files:**
- Create: `skills/subagent-driven-development/scripts/task-worktree`
- Test: `tests/claude-code/test-task-worktree.sh`
- Modify: `tests/claude-code/run-skill-tests.sh` (register new test)

**Interfaces:**
- Consumes: `skills/subagent-driven-development/scripts/sdd-workspace` (existing script — resolves `<repo-root>/.superpowers/sdd/<plan-basename>/`).
- Produces (for Task 4's SKILL.md rewrite to reference by exact invocation):
  - `task-worktree add PLAN_FILE TASK_NUMBER [BASE_REF]` — creates a worktree at `<sdd-workspace>/tasks/task-<N>` on branch `sdd/<plan-slug>/task-<N>`, branched from `BASE_REF` (default `HEAD`). Prints the absolute worktree path to stdout on success (exit 0). Exit `2` on usage errors, missing plan file, or bad `BASE_REF`. Exit `3` if the worktree or branch already exists.
  - `task-worktree remove PLAN_FILE TASK_NUMBER` — removes the worktree directory and deletes its branch. Prints `removed <path>` on success (exit 0). Exit `2` on usage errors or missing plan file. Exit `3` if no such worktree exists.

- [ ] **Step 1: Write the failing test**

Create `tests/claude-code/test-task-worktree.sh`:

```bash
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
```

Make it executable: `chmod +x tests/claude-code/test-task-worktree.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-task-worktree.sh`
Expected: FAIL with "No such file or directory" (`task-worktree` doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `skills/subagent-driven-development/scripts/task-worktree`:

```bash
#!/usr/bin/env bash
# Create or remove a per-task git worktree for one wave of parallel
# implementers in subagent-driven-development. Each task gets its own
# worktree so parallel implementers never touch the same working tree.
#
# Usage:
#   task-worktree add PLAN_FILE TASK_NUMBER [BASE_REF]
#   task-worktree remove PLAN_FILE TASK_NUMBER
#
# add:    creates <sdd-workspace>/tasks/task-<N> on branch
#         sdd/<plan-slug>/task-<N>, branched from BASE_REF (default HEAD).
#         Prints the absolute worktree path.
# remove: removes the worktree and deletes its branch.
#         Prints "removed <path>".
set -euo pipefail

usage() {
  echo "usage: task-worktree add PLAN_FILE TASK_NUMBER [BASE_REF]" >&2
  echo "       task-worktree remove PLAN_FILE TASK_NUMBER" >&2
}

if [ $# -lt 1 ]; then
  usage
  exit 2
fi

cmd=$1
shift

case "$cmd" in
  add)
    if [ $# -lt 2 ] || [ $# -gt 3 ]; then usage; exit 2; fi
    plan=$1
    n=$2
    base=${3:-HEAD}
    ;;
  remove)
    if [ $# -ne 2 ]; then usage; exit 2; fi
    plan=$1
    n=$2
    ;;
  *)
    usage
    exit 2
    ;;
esac

[ -f "$plan" ] || { echo "no such plan file: $plan" >&2; exit 2; }

script_dir=$(cd "$(dirname "$0")" && pwd)
workspace=$("$script_dir/sdd-workspace" "$plan")
slug=$(basename "$plan" .md)
wt_dir="$workspace/tasks/task-$n"
branch="sdd/$slug/task-$n"

if [ "$cmd" = add ]; then
  git rev-parse --verify --quiet "$base" >/dev/null || { echo "bad BASE_REF: $base" >&2; exit 2; }
  if [ -d "$wt_dir" ] || git rev-parse --verify --quiet "$branch" >/dev/null; then
    echo "task worktree already exists for task ${n}: ${wt_dir} (branch ${branch})" >&2
    exit 3
  fi
  mkdir -p "$workspace/tasks"
  git worktree add -q "$wt_dir" -b "$branch" "$base"
  echo "$wt_dir"
else
  if [ ! -d "$wt_dir" ]; then
    echo "no task worktree for task ${n}: ${wt_dir}" >&2
    exit 3
  fi
  git worktree remove --force "$wt_dir"
  git worktree prune
  git branch -D "$branch" >/dev/null 2>&1 || true
  echo "removed $wt_dir"
fi
```

Make it executable: `chmod +x skills/subagent-driven-development/scripts/task-worktree`

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/claude-code/test-task-worktree.sh`
Expected: PASS (all assertions).

- [ ] **Step 5: Lint the new script**

Run: `scripts/lint-shell.sh skills/subagent-driven-development/scripts/task-worktree`
Expected: no errors. Fix any ShellCheck findings before continuing.

- [ ] **Step 6: Register the new test in the runner**

In `tests/claude-code/run-skill-tests.sh`, find (after Task 2's edit):

```bash
tests=(
    "test-worktree-path-policy.sh"
    "test-sdd-workspace.sh"
    "test-subagent-driven-development.sh"
    "test-writing-plans-parallel.sh"
    "test-brainstorming-parallel.sh"
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
)
```

- [ ] **Step 7: Commit**

```bash
git add skills/subagent-driven-development/scripts/task-worktree tests/claude-code/test-task-worktree.sh tests/claude-code/run-skill-tests.sh
git commit -m "feat(subagent-driven-development): add task-worktree script for per-task isolation"
```

---

### Task 4: `subagent-driven-development` — dependency graph and wave dispatch

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md`
- Test: `tests/claude-code/test-sdd-parallel-waves.sh`
- Modify: `tests/claude-code/run-skill-tests.sh` (register new test)

**Interfaces:**
- Consumes: `task-worktree add|remove` from Task 3 (exact CLI documented above). `Depends on` field convention from Task 1.
- Produces: nothing further downstream — this is the last task in the plan.

- [ ] **Step 1: Write the failing content test**

Create `tests/claude-code/test-sdd-parallel-waves.sh`:

```bash
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
```

Make it executable: `chmod +x tests/claude-code/test-sdd-parallel-waves.sh`

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/claude-code/test-sdd-parallel-waves.sh`
Expected: FAIL — `Never dispatch multiple implementation subagents in parallel` is still present, and the other patterns aren't yet.

- [ ] **Step 3: Replace the "never parallel" line with wave-scoped guidance**

In `skills/subagent-driven-development/SKILL.md`, find:

```markdown
- Record the implementer's agent identity from the dispatch result —
  fix-loop rounds 1-3 resume this agent.
- Never dispatch multiple implementation subagents in parallel (conflicts).

Template: [implementer-prompt.md](implementer-prompt.md)
```

Replace with:

```markdown
- Record the implementer's agent identity from the dispatch result —
  fix-loop rounds 1-3 resume this agent.
- Multiple implementers may run at once only as part of the same wave (see
  Wave Dispatch below), each isolated in its own task worktree. Never
  dispatch two implementers into the same working tree at once — that is
  still a conflict.

Template: [implementer-prompt.md](implementer-prompt.md)
```

- [ ] **Step 4: Add the Wave Dispatch section**

In `skills/subagent-driven-development/SKILL.md`, find the boundary between Setup and Model Selection:

```markdown
Present everything you find to your human partner as one batched question —
each finding beside the plan text that mandates it, asking which governs —
before execution begins, not one interrupt per discovery mid-plan. If the
scan is clean, proceed without comment. The review loop remains the net for
conflicts that only emerge from implementation.

## Model Selection
```

Replace with:

```markdown
Present everything you find to your human partner as one batched question —
each finding beside the plan text that mandates it, asking which governs —
before execution begins, not one interrupt per discovery mid-plan. If the
scan is clean, proceed without comment. The review loop remains the net for
conflicts that only emerge from implementation.

## Wave Dispatch

Every task declares `Depends on: Task N, Task M` or `Depends on: None`.
Use this — not inference from prose — to compute which tasks can dispatch
together.

**Compute the ready set:** tasks not yet marked complete in the ledger
whose every `Depends on` entry IS marked complete. At the start, this is
every task listing `None`.

**Form a wave:** take up to **4** ready tasks (the concurrency cap). If
more than 4 are ready, the rest wait for the next wave — do not exceed the
cap to clear a backlog faster.

**Dispatch the wave:**

- **Wave size 1:** unchanged from the rest of this skill — dispatch
  directly in the plan's working tree, no worktree overhead, one Task Loop
  iteration (below) as written.
- **Wave size 2+, `Workflow` tool available (Claude Code):** delegate the
  wave to a `Workflow` script with `isolation: 'worktree'` that
  `pipeline()`s each task's implementer dispatch → task review → fix loop
  through its own isolated worktree, and returns each task's outcome
  (DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED, commit range,
  review verdict). Interpret each returned outcome exactly as Handle the
  Report and Review the Task below describe — the Workflow run is a
  delivery mechanism for the same per-task loop, not a different process.
- **Wave size 2+, no `Workflow` tool:** for each task in the wave, run
  `scripts/task-worktree add PLAN_FILE N` (from this skill's directory) to
  create `<sdd-workspace>/tasks/task-N` on branch
  `sdd/<plan-slug>/task-N`, branched from the plan branch's current HEAD.
  Dispatch that task's implementer with its working directory set to that
  worktree — everything else in the Task Loop below (task brief, report
  file, review, fix loop) proceeds per task exactly as written, just
  rooted in the task's own worktree instead of the plan's working tree.

**Merge on completion, not on wave completion:** the instant a task's
review clears (including any fix-loop rounds), merge it into the plan
branch immediately:

```bash
git -C <plan-worktree-path> merge --no-ff sdd/<plan-slug>/task-<N>
```

then `scripts/task-worktree remove PLAN_FILE N` to delete the task
worktree and branch, then append the ledger entry as usual. Do this one
task at a time, in the order tasks finish review — do not wait for the
rest of the wave. A merge conflict is a signal the `Depends on` graph
missed something real: resolve it if trivial, otherwise stop and ask your
human partner which task's changes should win.

**Open the next wave:** once every task in the current wave is merged,
recompute the ready set (a task blocked only on now-complete tasks becomes
ready) and repeat.

## Model Selection
```

- [ ] **Step 5: Note the wave loop replaces the single-task loop in the "More tasks remain?" step**

In `skills/subagent-driven-development/SKILL.md`, find:

```markdown
### 5. Complete the task

When the review comes back clean — or every open finding is parked with a
ruling at the cap — append the completion line to the ledger in the same
message as your other bookkeeping:

- `Task <N>: complete (commits <base7>..<head7>, review clean)`
- `Task <N>: complete (commits <base7>..<head7>, <K> parked)` after a
  tripped breaker

Then mark the todo complete and move on. Never move to the next task while
the review has open Critical/Important issues that are neither fixed nor
parked-with-ruling at the cap.
```

Replace with:

```markdown
### 5. Complete the task

When the review comes back clean — or every open finding is parked with a
ruling at the cap — merge the task per Wave Dispatch's "Merge on
completion" (if it ran in its own worktree) and append the completion line
to the ledger in the same message as your other bookkeeping:

- `Task <N>: complete (commits <base7>..<head7>, review clean)`
- `Task <N>: complete (commits <base7>..<head7>, <K> parked)` after a
  tripped breaker

Then mark the todo complete and move on. Never move to the next task while
the review has open Critical/Important issues that are neither fixed nor
parked-with-ruling at the cap. Once every task in the current wave is
merged, return to Wave Dispatch to open the next wave.
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/claude-code/test-sdd-parallel-waves.sh`
Expected: PASS (all assertions).

- [ ] **Step 7: Run the full fast test suite**

Run: `bash tests/claude-code/test-sdd-workspace.sh && bash tests/claude-code/test-task-worktree.sh && bash tests/claude-code/test-writing-plans-parallel.sh && bash tests/claude-code/test-brainstorming-parallel.sh && bash tests/claude-code/test-sdd-parallel-waves.sh && bash tests/claude-code/test-worktree-path-policy.sh`
Expected: all PASS — confirms none of the four skill/script tasks regressed each other.

- [ ] **Step 8: Register the new test in the runner**

In `tests/claude-code/run-skill-tests.sh`, find (after Task 3's edit):

```bash
tests=(
    "test-worktree-path-policy.sh"
    "test-sdd-workspace.sh"
    "test-task-worktree.sh"
    "test-subagent-driven-development.sh"
    "test-writing-plans-parallel.sh"
    "test-brainstorming-parallel.sh"
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
)
```

- [ ] **Step 9: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md tests/claude-code/test-sdd-parallel-waves.sh tests/claude-code/run-skill-tests.sh
git commit -m "feat(subagent-driven-development): dispatch independent tasks in parallel waves"
```

---

## Post-plan note (not a task — informational)

`tests/claude-code/test-subagent-driven-development.sh` and
`test-subagent-driven-development-integration.sh` invoke the live `claude`
CLI to ask the agent to *describe* the skill's behavior (see that file's
own header comment). Neither asserts the removed "never parallel" line, so
they don't need code changes as part of this plan, but they are the
appropriate place to add live-agent coverage of wave dispatch later if
you want scenario-level confidence beyond this plan's grep-based checks —
running them costs real `claude` invocations and 10-30 minutes for the
integration file, which is why this plan does not require running them as
part of any task's TDD loop.
