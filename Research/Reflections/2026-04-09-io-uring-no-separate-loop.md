---
date: 2026-04-09
session_objective: Review IO.Run+descriptor implementation, advise on io_uring Completions integration
packages:
  - swift-io
  - swift-kernel-primitives
  - swift-kernel
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: research_topic
    target: multishot-buffer-groups-reader-writer-impact.md
    description: "Do multishot recv + provided buffer groups change Reader/Writer abstraction design?"
  - type: skill_update
    target: implementation
    description: "Added [IMPL-087] Question Whether the Component Needs to Exist"
  - type: no_action
    description: "[package] IO Completions target shrink — execution task, tracked in io-uring-integration architecture handoff"
---

# io_uring Does Not Need Its Own Event Loop

## What Happened

Session continued from the architectural simplification (previous reflection).
Two activities: (1) reviewed the other agent's `IO.Run+descriptor.swift`
implementation (clean, correct, approved), (2) reviewed and challenged the
Completions integration plan.

The Completions plan proposed creating `IO.Completion.Loop` — a separate
executor with its own OS thread mirroring `IO.Event.Loop`. Through
Socratic questioning, the user drove to a fundamental insight: **io_uring
does not need a poll thread at all.**

The reasoning chain:
1. io_uring submissions are non-blocking ring buffer writes — no thread needed
2. io_uring completions can be discovered via eventfd registered with epoll
3. The Events loop already blocks on `epoll_wait` — piggybacking is free
4. Therefore: one thread on Linux handles both readiness AND completions
5. On Windows, IOCP IS the event loop — it replaces epoll, doesn't supplement it
6. On Darwin, kqueue only — no proactor backend

The other agent then produced `Research/io-uring-integration-architecture.md`
(v2) with deep prior art analysis (monoio, libxev, glommio, tokio-uring) and
advanced io_uring features (multishot, SQPOLL, provided buffer groups). The
eventfd integration was experimentally confirmed (100K NOPs, 13ms). Steps 1-3
of the execution sequence were completed (Kernel.Completion types at L1,
Wakeup.Channel extracted).

Advised the agent on: experiment-first validation, submission path decision
(MPSC + SINGLE_ISSUER), and realistic deletion estimate (~30 files survive,
not ~10).

## What Worked and What Didn't

**Worked**: The user's questioning technique — "why does it need a poll
thread?" then "are you SURE you need an event loop?" — each question
stripped away an assumption. The first question eliminated the second thread.
The second question revealed that the conventional pattern (poll thread per
backend) was cargo-culted from frameworks that didn't have Swift's executor
model or io_uring's eventfd integration.

**Worked**: Prior art validation. monoio's `poll-io` feature confirmed that
epoll CAN be subordinate to io_uring (PollAdd SQE), and our design inverts
this (io_uring subordinate to epoll via eventfd). Both achieve one thread.
Neither Tokio nor any major framework truly runs both concurrently as
co-equal loops — this is a universal design constraint, not our limitation.

**Didn't work**: The initial Completions plan (from the other agent) proposed
Option A (separate loop) uncritically. It was well-researched within its frame
but started from the wrong premise: "Completions needs a loop, how should we
build it?" The right question was: "Does Completions need a loop at all?"

## Patterns and Root Causes

**Pattern: question the premise before optimizing the solution.** The plan
for `IO.Completion.Loop` was technically sound — correct executor integration,
proper shutdown, matching the Events pattern. But it solved a problem that
didn't need to exist. The proactor model's defining property is that the
kernel does the work. A user-space poll thread is the reactor's constraint,
not the proactor's.

This is the same pattern as the IO Executor deletion earlier in the session:
35 files of infrastructure built from a theoretical design rather than from
need. The question "does this need to exist?" consistently produces larger
simplifications than "how should this be implemented?"

**Connection to prior sessions**: The "no actor" decision in Completions
(from `completion-queue-ownership-redesign.md`) was an earlier instance of
the same insight — the actor was removed because the proactor's 1:1 model
doesn't need fan-out serialization. The "no separate loop" insight is the
next step: the proactor doesn't need its own thread either, for the same
reason (the kernel does the work, not user-space).

**Root cause of conventional bias**: Every IO framework tutorial starts with
"create an event loop." This creates the assumption that every backend needs
one. io_uring's design (shared-memory rings, eventfd notification) was
specifically designed to break this assumption — but most frameworks still
impose the old structure on top of it.

## Action Items

- [ ] **[research]** Investigate whether multishot recv + provided buffer groups change the Reader/Writer abstraction design — the 1:N completion model may require a different internal buffer strategy than the 1:1 model assumed by the current IO.Reader
- [ ] **[skill]** implementation: Add guidance — "question whether the component needs to exist before designing how it should work" as a corollary of [IMPL-000] (call-site-first design applied to architecture)
- [ ] **[package]** swift-io: The 62-file IO Completions target should shrink to ~30 files after integration — operation types (Read/Write/Accept/Connect) and their results survive; poll thread, separate loop, entry/submission machinery are absorbed into the Events Loop
