# Worklog Timing Reliability — Design

**Status:** Approved by user, fork-local change (not intended for upstream PR).

## Goal

Fix three real reliability gaps found after using the Jira worklog timing
feature (`docs/superpowers/specs/2026-08-03-jira-worklog-timing-design.md`)
in production: automatic timing sometimes never engages at all, its
failure is silent, and a Jira issue key volunteered early in the
conversation is never captured before the end-of-phase prompt.

## Motivation

Across 2 real feature sessions (different project, plugin already
updated to the version with worklog timing), the user reported: they
gave the Jira ticket at the start of the conversation, but at the end of
the phase they got no summary and no publish prompt at all — they had to
estimate the time manually outside the skill's flow. A third session,
where they didn't need tracking, did get the "Is this Jira-tracked
work?" prompt correctly, confirming the feature works when it engages —
the problem is that it doesn't always engage, and when it doesn't,
nothing tells the user.

Root cause, diagnosed by inspection of `skills/brainstorming/SKILL.md`,
`skills/writing-plans/SKILL.md`, and `skills/subagent-driven-development/SKILL.md`:

1. `scripts/time-log start` lives in a standalone paragraph, not in
   brainstorming's own enumerated 9-item checklist (the one the skill
   explicitly requires a todo per item for) — nothing forces it to
   happen, so a real session can skip it under the weight of everything
   else happening at conversation start.
2. If `start` never ran, `scripts/time-log end` fails (exit 3, no phase
   open) — and none of the three skills has any instruction for that
   failure. The agent silently continues to the next step with no
   summary, no error, no fallback.
3. Even when timing works end-to-end, the Jira issue key is only ever
   read/asked at end-of-phase. A key volunteered earlier in the
   conversation (e.g. in the user's opening message) is never captured
   before then, so it's wasted until the first phase-end reaches it.

## Scope decision

Fork-local change, same as the two prior worklog-timing plans — no
upstream PR process applies. Modifies the same three skills again
(`brainstorming`, `writing-plans`, `subagent-driven-development`); no new
scripts or files. `scripts/time-log` itself is unchanged — this is a
reliability fix to how the skills invoke it, not to the script.

Two approaches were considered:

- **Chosen: harden the existing prose-based instructions** — move
  `time-log start` into each skill's already-enforced entry point
  (brainstorming's numbered checklist item 1; writing-plans/SDD's
  "Announce at start" line), add explicit fallback behavior for a failed
  `end`, and add an early-capture rule for a volunteered Jira key. Low
  risk, no new infrastructure, stays multi-harness (no Claude-Code-only
  mechanism).
- **Rejected for now: enforce `time-log start` via a Claude Code hook**
  (e.g. `SessionStart`) so it's code-triggered instead of
  instruction-followed. Genuinely more reliable, but Claude-Code-only
  (breaks portability to the other harnesses this repo supports) and
  requires touching the *consuming* project's `.claude/settings.json`,
  not just this skills repo — a much bigger, more invasive change than
  today's actual problem warrants. Left as a future option if the
  chosen approach proves insufficiently reliable in practice.

## Section 1: Enumerate the timing start, don't leave it as loose prose

**`brainstorming`:** checklist item 1 changes from "Explore project
context — check files, docs, recent commits" to "Start time tracking
(`scripts/time-log start`) and explore project context — check files,
docs, recent commits." This folds the time-log call into the same item
the skill already forces a todo for, instead of a separate paragraph
competing with everything else happening at conversation start.

**`writing-plans` and `subagent-driven-development`:** neither has an
enumerated checklist like brainstorming — both are prose sections. For
these two, the `time-log start` call moves to be the action immediately
following each skill's existing "Announce at start" line (writing-plans:
"I'm using the writing-plans skill..."; SDD: "I'm using Subagent-Driven
Development..."), tying it to an action both skills already perform
consistently at the very start of every real invocation, rather than
living as a standalone paragraph further down the file.

## Section 2: Fallback when `time-log end` fails

At the point each skill currently calls `scripts/time-log end <topic>`
without error handling, add: if the call fails (exit 3, no phase was
ever started), do not silently continue — tell the human partner
automatic tracking wasn't captured for this phase and offer to log an
approximate duration manually (e.g. "2h 30m"). If they give one, use it
in place of `ACTIVE_HUMAN` for the rest of the publish flow (using "now"
in place of `STARTED_ISO` if needed); if they decline, skip the publish
flow entirely for that phase. This turns today's silent gap — and the
user's own manual workaround outside the skill's flow — into a supported
path inside the same flow.

## Section 3: Capture an already-given Jira key immediately

Immediately after the (now-enumerated) `time-log start` call in all
three skills, add: if the human partner already mentioned a Jira issue
key anywhere in the conversation before this point (e.g. in their
opening request), call `scripts/time-log set-jira <topic> <ISSUE-KEY>`
right now rather than waiting for the end-of-phase prompt. Since the
existing end-of-phase logic already skips re-asking once `JIRA:` is
resolved, this makes that skip apply starting from the very first phase
instead of only from the second phase onward.

## Out of scope

- No changes to `scripts/time-log` itself — the script's behavior
  (exit codes, subcommands, PHASE disambiguation) is unchanged.
- No hook-based enforcement (Claude Code `SessionStart` or similar) —
  considered and explicitly deferred, see Scope decision above.
- No changes to the `addWorklogToJiraIssue` call shape or the `cloudId`
  resolution flow — those are unaffected by this reliability fix.
