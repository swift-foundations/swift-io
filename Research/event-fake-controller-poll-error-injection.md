---
title: Poll-Error Injection in IO.Event.Fake.Controller — Marginal Confidence vs Cost
version: 0.1.0
status: IN_PROGRESS
tier: 1
created: 2026-04-16
last_updated: 2026-04-16
applies_to:
  - swift-io
  - IO.Event.Fake
---

# Context

The polling-tick `throws(E)` thunk session added a pure classifier
(`IO.Event.Loop.RetryDecision`) with unit tests covering the full
EINTR/ENOMEM/EAGAIN/fatal policy. The classifier is pure, so the tests
are fast and complete for the decision surface. What they do NOT
exercise is the full tick→retry→wait cycle as an integration — the
feedback from the classifier into the run loop's scheduling, the
interaction with `Kernel.Thread.yield()` on ENOMEM, the ordering
guarantees when a fatal error arrives mid-drain. `IO.Event.Fake.Controller`
is the existing mock-driver surface for integration tests; it currently
cannot inject poll errors to trigger the full cycle. Adding
poll-error injection would close that gap, at the cost of expanding
the Fake's API and test-author cognitive load.

# Question

Should `IO.Event.Fake.Controller` gain poll-error injection to
integration-test the full tick→retry→wait cycle? Specifically:

- What additional bugs would be caught by integration tests over the
  current pure-classifier tests? (Coverage gap analysis.)
- What's the API surface cost — one new method, or a full
  error-schedule DSL?
- Does the injection need to cover all error classifications (EINTR,
  ENOMEM, EAGAIN, fatal), or is one class sufficient?
- Are there existing integration tests in swift-io that would benefit
  immediately, or is this speculative?

# Prior Work

- `swift-foundations/swift-io/Sources/IO Events/IO.Event.Fake.Controller.swift`
- `swift-foundations/swift-io/Tests/IO Events Tests/IO.Event.Loop.RetryDecision.Tests.swift`
- `swift-foundations/swift-io/Research/io-events-concurrent-readiness-dispatch.md`
- Source reflection: `swift-io/Research/Reflections/2026-04-15-polling-tick-throws-thunk-over-result.md`

# Analysis

_Stub — to be filled in during investigation._

Key sub-questions to work through:

- Compare the current integration-test coverage (what paths are
  exercised via `Fake.Controller`) against the tick→retry→wait cycle
  surface area.
- Estimate the implementation cost of the injection API (small — a
  scheduled-errors queue — to medium — a full DSL).
- If deferred, what's the leading indicator that would re-open the
  question? (A production bug the pure classifier missed? A refactor
  that changes the tick→wait binding?)

# Outcome

_Placeholder — to be filled when analysis completes._

# Provenance

Source: `swift-foundations/swift-io/Research/Reflections/2026-04-15-polling-tick-throws-thunk-over-result.md` action item.
