---
date: 2026-04-16
session_objective: Build IO Completions Test Support with FakeBackend and cross-platform witness-level tests to close the macOS coverage gap
packages:
  - swift-io
  - swift-executors
  - swift-institute
status: processed
processed_date: 2026-04-24
triage_outcomes: see reflections-processing run 2026-04-24
---

# IO Completions Test Support: From Fake to Witness Factory

## What Happened

Session began with tick-isolation handoff verification (supervisor block, 5 acceptance criteria verified via `swift test` + grep + git log). Merged `unsafe-audit` into `main` preserving the Phase 3 HANDOFF.md. Then shifted to IO Completions test coverage — rated C+ (18 source files, 1 Linux-only smoke test, 0% macOS coverage).

Built `IO Completions Test Support` target with `Kernel.Completion.Fake` (in-memory backend). Iterated through four design passes:

1. **Scaffold** (`8f476055`): FakeBackend with submission recording + manual injection.
2. **Coordination** (`f93a0ba8`): Added `onSubmit` auto-responder (synchronous CQE generation in submit closure — single-tick round-trip), startup gate (`holdUntilStarted`/`start` condvar to prevent executor thread racing past `handle.actor = self`), `waitUntilSubmitted` condvar. 15 Fake-driven tests.
3. **Witness factory** (`0237de13`): `IO.completionsTest()` — returns `IO.completions()` on Linux, `IO.events()` on macOS. Absorbed 3 Linux-only smoke tests into 4+1 cross-platform witness tests with real pipe I/O.
4. **Trim** (`4aa892ee`, `a7daa030`): Deleted 6 Fake tests made redundant by Witness tests. Removed unused FakeBackend APIs (inject, waitUntilSubmitted, closeCount, wakeupCount, reset). Renamed `FakeBackend` → `Fake` per [API-NAME-001]. Deleted trivial Cancellation unit tests. Final: 63/29 green.

Also added [IMPL-083] Custom-Executor-to-Actor Bridge Pattern to implementation skill, documenting the Handle + SE-0424 triad and the 10 closed avenues.

## What Worked and What Didn't

**Worked**: The user's push toward `IO.completionsTest()` was the key design improvement. My initial instinct (parameterized tests with `@Test(arguments:)`) would have produced verbose test bodies branching on backend. The factory pattern — one body, real I/O, backend opaque — is simpler, matches `IO.default()`, and is strictly more correct (tests verify actual bytes through the full stack, not synthetic CQE values).

**Worked**: The startup gate discovery. The Fake has no blocking notification wait (the real kernel uses eventfd). Without the gate, the executor thread's first tick fires before `handle.actor = self` completes — the actor appears dead immediately. The condvar gate blocks the Fake's drain until the factory calls `start()`. This is NOT a timing hack — it's a structural replacement for the missing blocking wait.

**Didn't work**: Built too much FakeBackend infrastructure upfront. `waitUntilSubmitted`, bulk `inject`, `closeCount`, `wakeupCount`, `reset` — all removed in the final trim. Designed for cancel-handshake Fake tests that were never written because the cancel test went into the Witness suite as Linux-only real-kernel instead.

**Didn't work**: The initial Fake-only Actor integration tests (read/write/ready success) were redundant once the Witness factory existed. Should have recognized earlier that synthetic-CQE tests add no value when real-I/O tests exist for the same contract.

## Patterns and Root Causes

**Pattern: "Test the contract, not the mechanism."** The Fake tests I initially wrote tested that the actor produces the right output when given synthetic inputs. The Witness tests verify the actual I/O contract — bytes in, bytes out, through the full stack. The Fake's remaining value is narrow: observe internal state (submissions, flush count, IDs) and inject error conditions that real I/O can't produce on demand. This maps to a general principle: test doubles should test what real backends CAN'T (deterministic error injection, internal observation), not duplicate what real backends already prove.

**Pattern: "Factory over parameterization."** `IO.completionsTest()` is one line. `@Test(arguments: CompletionTestBackend.allCases)` with per-backend branching is 20+ lines. The factory pushes the platform conditional to one location (Test Support) and keeps test bodies unconditional. This is [IMPL-000] Call-Site-First Design applied to tests: write the ideal test expression first, make the infrastructure support it.

**Pattern: "The startup gate is a Fake's notification substitute."** When replacing a blocking kernel mechanism (eventfd, kqueue, IOCP) with an in-memory Fake, the Fake MUST provide an equivalent blocking primitive. Without it, the executor thread races through the run loop unconstrained. The condvar gate is the general solution — it blocks until the caller signals that setup is complete.

## Action Items

- [ ] **[skill]** testing: Add [TEST-0xx] convention for cross-platform test witness factories — the `IO.completionsTest()` pattern (one factory, backend-opaque, real I/O, conditional per platform in Test Support) should be documented as the canonical approach for strategy-parameterized testing
- [ ] **[package]** swift-io: Run Linux Docker `swift test` to verify witness tests pass against real io_uring — macOS green is confirmed but Linux completions path is untested this session
- [ ] **[skill]** implementation: Add a note to [IMPL-083] about the startup gate pattern — when a Fake replaces a blocking kernel wait, the Fake's drain must gate on a condvar until the actor init completes
