# Jira Worklog Timing — Design

**Status:** Approved by user, fork-local change (not intended for upstream PR).

## Goal

Automatically time how long each phase of the brainstorming → writing-plans
→ subagent-driven-development cycle actually takes — excluding time spent
waiting on the human partner's responses — and offer to log that time to a
Jira issue's worklog at the end of each phase, without forcing every piece
of work through Jira.

## Motivation

The user works in Jira-tracked repos and currently has no way to know how
long a design, a plan, or an individual implementation task actually took
without watching a clock themselves. A session already has a Jira MCP
connector available (`addWorklogToJiraIssue`), so the missing piece is
purely: measure active time per phase, and offer to publish it.

## Scope decision

Fork-local change, same as the parallel-planning-and-execution work — no
upstream PR process applies. Instruments three existing skills
(`brainstorming`, `writing-plans`, `subagent-driven-development`) rather
than creating parallel variants, and adds one new shared script rather
than duplicating timing logic per skill.

## Section 1: Architecture

**`scripts/time-log`** (repo root, alongside `scripts/lint-shell.sh` —
shared by three skills, not owned by one): subcommands `start TOPIC
PHASE`, `pause TOPIC`, `resume TOPIC`, `end TOPIC`, `summary TOPIC PHASE`.
Each subcommand captures `date +%s` and appends a line to that topic's
worklog file. `summary`/`end` compute active duration = (last `end` −
`start`) − Σ(`resume` − `pause`) and print both a human-readable duration
(`Xh Ym`) and the phase's ISO 8601 start time (for the Jira `started`
field).

**`.superpowers/worklog/<topic-slug>.md`**: one file per topic, created by
the first `time-log start` call for that topic. `<topic-slug>` is the same
slug brainstorming/writing-plans already use for spec/plan filenames
(`YYYY-MM-DD-<topic>`), so the file is addressable identically across all
three phases without inventing a new ID. Git-ignored scratch, same
pattern as `.superpowers/sdd/`.

Script exit codes follow this repo's existing convention: `2` for
usage/argument errors, `3` for state conflicts (phase already open,
mismatched pause/resume).

## Section 2: Checkpoints per skill

**`brainstorming`:**
- `time-log start <topic> brainstorming` once the topic slug is known
  (before the first clarifying question).
- `time-log pause <topic>` / `resume <topic>` around every point that
  waits on the user: `AskUserQuestion` calls, the visual-companion offer,
  each design-section approval, the written-spec review gate.
- `time-log end <topic>` after the spec self-review, before invoking
  writing-plans — followed by the summary + Jira-publish prompt (Section
  4).

**`writing-plans`:**
- `time-log start <topic> writing-plans` at skill start.
- Pause/resume around the one real wait point: the
  Subagent-Driven-vs-Inline-Execution offer at the end.
- `time-log end <topic>` just before that offer, then summary + publish
  prompt.

**`subagent-driven-development`:**
- `time-log start <topic> task-N` at the same point BASE is recorded
  (implementer dispatch for task N).
- Pause/resume around real waits within the loop: relaying an
  implementer's question to the human, or a plan-vs-review conflict that
  needs a human decision. (Routine dispatch/review/fix-loop activity is
  not a wait point — the skill's "continuous execution" principle is
  unaffected.)
- `time-log end <topic>` when the task is marked complete in the ledger,
  then summary + publish prompt with phase `task-N`.
- One more `start`/`end` cycle with phase `final-review` around the
  whole-branch final review.

## Section 3: Worklog file format

Plain text, append-only lines, one file per topic:

```
# time-log — topic: 2026-08-03-my-feature — jira: PROJ-123
start brainstorming 1754200000
pause brainstorming 1754200120
resume brainstorming 1754200400
end brainstorming 1754201000
start writing-plans 1754201050
end writing-plans 1754202000
start task-1 1754202100
pause task-1 1754202300
resume task-1 1754202450
end task-1 1754203000
```

- First line is metadata only, written by the first `time-log start` call
  if the file doesn't exist yet: `# time-log — topic: <slug> — jira:
  <ISSUE-KEY|none>`.
- If the Jira issue is already resolved (line says an issue key or
  `none`), `time-log` and the calling skill never ask again for that
  topic — matches "ask once at the start."
- `time-log start` on a phase that already has an unclosed `start` line
  (resumed after compaction) errors exit 3 instead of duplicating the
  entry; skills treat that error as "already open, just continue."
- `pause`/`resume` calls that don't alternate correctly (pause without a
  prior open pause, resume without a pending pause) error exit 2.
- All timestamps are epoch seconds (`date +%s`); `summary`/`end` convert
  to `Xh Ym` for display and to ISO 8601 for the Jira `started` field.

## Section 4: Jira publish flow

`addWorklogToJiraIssue` requires `cloudId`, `issueIdOrKey`, `timeSpent`
(e.g. `"1h 30m"`); accepts optional `started` (ISO 8601) and
`commentBody`.

**Resolving `cloudId`:** the first time a publish is confirmed in the
conversation, call `getAccessibleAtlassianResources`. One site → use it
automatically. Multiple sites → ask once, reuse for the rest of the
session. Not persisted to the worklog file (account-level, not
topic-level).

**At each phase end** (`time-log end` → `time-log summary`):
- If the topic's worklog file has no resolved `jira:` value yet (first
  phase-end in the whole cycle): ask "Is this Jira-tracked work? If so,
  give me the issue key." A "no" writes `jira: none` and the skill never
  asks again for this topic, in any phase — no further publish prompts
  either.
- If an issue is already known: show the phase's active duration and ask
  whether to publish it — every phase end prompts individually.
- On confirmation: call `addWorklogToJiraIssue` with the resolved
  `cloudId`, `issueIdOrKey=<issue>`, `timeSpent=<from summary>`,
  `started=<phase's start timestamp, ISO 8601>`, and a phase-appropriate
  `commentBody` (e.g. `"Design/brainstorming: <topic>"`, `"Task 3:
  <title>"`, `"Final review: <topic>"`). Report the result back to the
  user.

**Fallback:** if the Jira MCP connector isn't available/connected this
session, the skill still shows the summary and tells the user it couldn't
publish automatically, so they can log it manually.

## Section 5: Cleanup

`.superpowers/worklog/<topic-slug>.md` is **not** deleted by
`finishing-a-development-branch` — it stays as a local time record after
the cycle ends, independent of whether everything was published to Jira.
It remains git-ignored scratch, so it never touches the tracked repo.

## Out of scope

- No change to `finishing-a-development-branch`, `executing-plans`,
  `dispatching-parallel-agents`, or any skill other than the three named
  above.
- No new skill files — `time-log` is a script, not a skill.
- No per-checklist-item granularity within a phase (explicitly rejected —
  phase-level and per-task granularity only).
- No automatic Jira issue inference (e.g. from branch name); the issue
  key is always given by the user.
