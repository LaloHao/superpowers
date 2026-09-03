# Worklog Timing — Single Upfront Prompt — Design

**Status:** Approved by user, fork-local change (not intended for upstream PR).

## Goal

Replace the current per-phase "is this Jira-tracked? want to publish?"
prompting in the worklog timing feature (brainstorming / writing-plans /
subagent-driven-development) with a single upfront prompt per topic, asked
before any time tracking begins. Once answered, the rest of the topic's
phases behave automatically with no further prompts: either fully
instrumented and auto-published, tracked-but-not-published, or not
instrumented at all.

## Motivation

The user reported that on two real features, time was never tracked and
they had to enter an approximate duration by hand — even though they gave
the Jira ticket at the very start of the session. The current design asks
"is this Jira-tracked?" at the *end* of the first phase, which is too
late if something upstream goes wrong, and re-confirms "publish this?" at
every single phase end, which is unnecessary friction once the user has
already committed to tracking for a given ticket.

## Scope decision

Fork-local change, same as the prior two worklog-timing plans. This
supersedes significant portions of the "Time tracking" and "Time tracking
and Jira publish" sections in all three skills, and adds a small amount
of new `scripts/time-log` surface. No new skill files.

## Section 1: State model and persistence

The worklog file's header `jira:` field gains a fourth value. Four states
total:

| Value | Meaning |
|---|---|
| `unknown` | Not yet asked for this topic (default when no file exists) |
| `disabled` | User declined tracking — zero `time-log` instrumentation for the rest of this topic, in every phase |
| `none` | Tracking wanted, no Jira ticket — instrument normally, show duration each phase, never offer to publish |
| `<ISSUE-KEY>` | Tracking wanted, ticket given — instrument normally, auto-publish at each phase end, never ask again |

**`scripts/time-log` changes:**

- New read-only subcommand: `time-log status TOPIC` — prints `JIRA:
  <value>` (the header field), or `JIRA: unknown` if the topic's worklog
  file doesn't exist yet. Does not require any phase to be started. This
  is what each skill checks before doing anything else, to know whether
  this topic has already been asked.
- `time-log set-jira TOPIC VALUE` is relaxed to create the worklog file
  (with the standard header) if it doesn't exist yet, instead of exiting
  3. This is required because the `disabled` and `none` states can be
  recorded before any `time-log start` has ever run for the topic.
- `start`/`pause`/`resume`/`end`/`summary` are otherwise unchanged from
  the existing implementation (including the multi-phase-open `PHASE`
  disambiguation from the reliability plan).

## Section 2: Unified upfront-prompt flow (all three skills)

Whichever of `brainstorming`, `writing-plans`, or
`subagent-driven-development` is the first to touch a given topic in a
session runs this flow as its very first action — before exploring
context, before Task 1's dispatch, before anything else:

1. Run `scripts/time-log status <topic>`.
2. **If `JIRA: unknown`** (first time this topic has been seen):
   - Ask: "Do you want time tracked for this task?"
     - **No** → `scripts/time-log set-jira <topic> disabled`. For the
       rest of this topic, in every phase of every skill, skip this
       entire flow silently and make zero `time-log` calls.
     - **Yes** → ask: "What Jira ticket does this correspond to? (or say
       it doesn't apply)"
       - A ticket key → `scripts/time-log set-jira <topic> <ISSUE-KEY>`.
       - No ticket → `scripts/time-log set-jira <topic> none`.
   - If the topic did not end up `disabled`, only now run
     `scripts/time-log start <topic> <phase>` to begin this phase's
     timer.
3. **If `JIRA: disabled`:** make no `time-log` calls this phase at all —
   proceed with the skill's normal work exactly as if this feature didn't
   exist.
4. **If `JIRA: none`:** instrument normally (`start`, pause/resume around
   real waits, `end`). At phase end, show the active duration. Never
   offer or attempt to publish.
5. **If `JIRA: <ISSUE-KEY>`:** instrument normally. At phase end, publish
   automatically: resolve `cloudId` via `getAccessibleAtlassianResources`
   if not already resolved this conversation (ask which site only if
   genuinely ambiguous — more than one site), then call
   `addWorklogToJiraIssue` with that `cloudId`, `issueIdOrKey=<the
   issue>`, `timeSpent=<ACTIVE_HUMAN>`, `started=<STARTED_ISO>`, and a
   phase-appropriate `commentBody`. Report the result. **No confirmation
   prompt** — the upfront "yes, ticket X" already was the consent.

This flow is identical across all three skills; each just supplies its
own phase name(s) (`brainstorming`, `writing-plans`, `task-N` /
`final-review` for SDD) and its own real wait-points for pause/resume.

## Section 3: What carries over vs. what's replaced

**Carries over unchanged:**
- Pause/resume around real human-wait points within a tracked phase.
- The fallback when `time-log end` fails unexpectedly (tell the human,
  offer a manual duration) — still applies whenever the state is `none`
  or an issue key (an `end` call happens); moot when `disabled` (no `end`
  call is ever made).

**Replaced (removed from all three skills):**
- The "early capture" logic from the prior reliability plan (call
  `set-jira` right after `start` if the ticket was already mentioned) —
  superseded, since the ticket is now asked before `start` ever runs.
- The "ask if `JIRA: unknown`" and "ask whether to publish" logic at each
  phase end — replaced by the automatic behavior in Section 2, driven
  entirely by the state resolved once at the topic's first phase.

## Section 4: Test impact

- `tests/claude-code/test-time-log.sh` gains coverage for: `status` on a
  missing topic (prints `JIRA: unknown`, doesn't create a file), `status`
  on an existing topic (prints the real header value), `set-jira`
  creating a file that doesn't exist yet (previously exit 3), and the
  `disabled` value round-tripping through `set-jira`/`status` like any
  other value.
- `tests/claude-code/test-brainstorming-worklog.sh`,
  `test-writing-plans-worklog.sh`, and `test-sdd-worklog.sh` are
  substantially rewritten (not just extended): assertions for the old
  per-phase-end "ask if unknown" / "ask to publish" text are removed and
  replaced with assertions for the new upfront two-question flow, the
  `disabled` state's "zero calls" instruction, and the "no confirmation
  prompt" auto-publish wording.

## Out of scope

- No change to `finishing-a-development-branch`, `executing-plans`,
  `dispatching-parallel-agents`, or `scripts/task-worktree`.
- No new skill files.
- No change to the `PHASE`-disambiguation mechanics from the reliability
  plan (still required as-is for SDD's concurrent waves).
- No cross-topic "ask once per conversation" behavior — confirmed
  per-topic scoping, matching the existing worklog-file-per-topic design.
