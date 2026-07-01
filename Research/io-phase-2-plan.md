# swift-io Phase 2 Plan

<!--
---
version: 1.0.0
created: 2026-04-14
status: DRAFT — awaiting author/user approval of sequencing
tier: 2
related:
  - swift-io/Research/io-architecture.md (v1.1 — CANONICAL)
  - swift-io/Research/io-performance-ceiling-measurement.md (TCA26 evidence)
  - swift-io/HANDOFF-io-layered-implementation.md (Phase 1 spec, local)
  - swift-io/HANDOFF-io-phase-1-author-review.md (bucket classification, local)
  - swift-io/HANDOFF-io-layered-implementation-review.md (design debate, local)
  - swift-io/HANDOFF-io-layered-implementation-review-response.md (design debate, local)
  - swift-io/HANDOFF-io-performance-measurement-response.md (perf decisions, local)
  - swift-io/Experiments/io-stacked-actor-bench/ (benchmark source)
  - swift-iso-9945/Research/frozen-accept-result.md (Accept.Result swap-sentinel workaround)
changelog:
  - v1.0: Initial Phase 2 plan. Commits to the proposed 2A → 2B → 2C → 2D
    sequencing after critical review; answers all three gating questions with
    explicit resolution criteria; enumerates per-sub-phase file-level changes,
    commit structure, test strategy, and verification gates; lists out-of-scope
    work and rejected framings.
---
-->

## 1. Scope

Phase 2 takes swift-io from a blocking-only coherent primitive to a fully
domain-agnostic dispatch layer serving three strategies (blocking, events,
completions) and composes cleanly with swift-sockets as the first domain
consumer. This plan is the execution contract for that work.

### 1.1 What Phase 2 Delivers

| Deliverable | Sub-phase |
|---|---|
| `Sockets.TCP.Listener` + `Sockets.TCP.Connection` in swift-sockets, blocking strategy, validated end-to-end by integration tests. | 2A |
| Migration of socket-specific Channel family from `swift-io/Sources/IO Events/` to swift-sockets (Bucket A + rescoped Bucket C). | 2B |
| Rename and retain reactor-generic runtime in `swift-io/Sources/IO Events/`; internal `IO.Events.Actor` wiring the runtime to the `IO` witness. | 2B |
| `IO.events(_:)` / `IO.events(on:)` factory; swift-sockets `TCPListener` upgraded to use events-strategy accept (poll-then-accept via `@_spi(ResourceBackend)` Selector access). | 2B |
| Migration of socket-specific Accept / Connect / Channel from `swift-io/Sources/IO Completions/` to swift-sockets; `Kernel.Descriptor` → `Kernel.Socket.Descriptor` type-correction on migration (Gap 4). | 2C |
| Internal `IO.Completions.Actor` wiring the proactor runtime to the `IO` witness. | 2C |
| `IO.completions(_:)` factory; swift-sockets completions code path. | 2C |
| `IO.platformBest(_:)` factory in the IO umbrella product with platform-conditional dispatch. | 2D |

### 1.2 What Phase 2 Does NOT Deliver

See §6 for the full out-of-scope list. Highlights:

- No cancellation/timeout composition through blocking / events / completions
  syscalls. Task cancellation propagates as Swift does today (awaitable
  suspension points); the reactor-poll-exit and `IORING_OP_ASYNC_CANCEL`
  integrations are Phase 5+ work.
- No swift-file-system bootstrap (`pread`, `pwrite`, `preadv`, `pwritev`,
  `openat`, `mmap`, `xattr`, `stat`). Separate package, separate plan.
- No swift-pipes (`splice`, `tee`, `sendfile`). Deferred indefinitely.
- No new Swift macros; `@Witness` remains the only witness macro in use.
- No `.mock` generation; `observe` + hand-written test doubles via the
  public `IO` init cover the testing story.

## 2. Gating Architectural Questions

Three questions gate concrete work. Each has an explicit resolution criterion:
an artifact that closes the gate and a sub-phase that blocks until it is
written.

### Q1 — Selector cross-package access (gates 2B step (v); cascades to 2C as Q1')

**Problem.** swift-sockets cannot implement events-strategy `accept` without
registering a listener fd with swift-io's `IO.Event.Selector` and awaiting
read-readiness. `package` visibility (SE-0386) is intra-package only; swift-io
and swift-sockets are separate Swift packages.

**Options.**

| Option | Mechanism | Cost |
|---|---|---|
| (a) `@_spi(ResourceBackend) public` on `Selector.register` / `deregister` + required siblings | Each consumer file opts in via `@_spi(ResourceBackend) import`. Boundary auditable with `grep`. | Per-consumer-file ceremony ([MOD-016] applies). |
| (b) Plain `public` documented as internal-use | No ceremony; API discovery surface unchanged; no gate on boundary. | Public API drift — anyone can register. |
| (c) New handle abstraction that swift-sockets opts into | Minimal surface; explicit ownership transfer. | One more concept; defers SPI decision. |

**Resolution criterion.** A §B.3 subsection of this plan, written at the end
of 2B step (ii) (Bucket C audit) and before step (iii) (SPI annotation),
names one option and documents:

- The exact public-facing signature swift-sockets will import.
- Which retained runtime files (`Selector.Register`, `Selector.Registration`,
  `Selector.Scope`, `Selector.Make`, `Selector.Shutdown`, `Runtime`, `Token`,
  `Interest+Hash`, possibly `Wakeup.Channel`) receive the SPI or remain
  internal.
- A one-paragraph justification citing the concrete swift-sockets code the
  decision supports.

The decision MUST be informed by 2A's output (the blocking-strategy
Listener's actual API surface reveals what events-strategy needs) and 2B
step (ii)'s rescoping of Bucket C storage / receivers.

**Prior position.** The architecture doc v1.1 Open-Questions section names
`@_spi(ResourceBackend)` as the leading option but does not commit. This
plan treats it as the default; any deviation demands explicit argumentation.

**Q1' for Completions.** The same question recurs for swift-sockets submitting
`IORING_OP_ACCEPT` / `IORING_OP_CONNECT` through swift-io's
`IO.Completion.Queue`. Answered in 2C with the same default (SPI public);
resolution criterion is an analogous §C.3 subsection.

### Q2 — Buffer-ownership contract under completions (gates 2C)

**Problem.** The `_read` witness signature
`(borrowing Kernel.Descriptor, Memory.Buffer.Mutable) async throws(IO.Error) -> Int`
is strategy-agnostic. Under blocking and events, the buffer lives on the
caller's stack across `try await` — trivially correct. Under io_uring, the
kernel holds a reference from SQE submission to CQE consumption. For
heap-owned buffers: fine. For stack-allocated `MutableSpan` views,
externally-registered buffers, or any storage decoupled from the caller's
frame lifetime: potential correctness trap.

**Options.**

| Option | Mechanism | Implication for the witness |
|---|---|---|
| (a) Document the invariant; accept the trap | One paragraph in `IO.swift` doc: "buffer valid for the duration of the single `try await`, strongest semantics under `platformBest`". | Unified `_read` retained. |
| (b) Split proactor into `_readRegistered` / `_writeRegistered` with kernel-managed buffers | Two strategies expose unified `_read`; completions exposes both `_read` (copy-bridge to internal buffer) and `_readRegistered` (zero-copy). | Witness grows to 6+ closures. `platformBest` must choose. |
| (c) Buffer-pool abstraction at swift-io layer | Caller opts into a pool; pool handles strategy-specific lifetime. | New public type. Unclear ergonomics. |

**Resolution criterion.** An empirical experiment at
`swift-io/Experiments/proactor-buffer-ownership/` (Linux, ~100–200 LOC,
io_uring) that:

1. Submits a `IORING_OP_READ` with a stack-allocated `Memory.Buffer.Mutable`
   pointing into a `MutableSpan` view of a local array.
2. `try await`s the CQE.
3. Verifies kernel held no stale pointer (completion reads back correct
   bytes; no crash under `-sanitize=address`).

The experiment's written conclusion (one paragraph) commits to option (a),
(b), or (c). Commit that conclusion to
`Research/io-proactor-buffer-ownership.md` before starting 2C step (i).

If the experiment invalidates (a) — i.e., kernel genuinely holds stale
pointer beyond the caller's frame — Phase 2C adds `_readRegistered` /
`_writeRegistered` to the witness. This cascades to Phase 2D: `platformBest`
either exposes the intersection (no `readRegistered`) or the strictest
contract (all strategies provide both, even if `readRegistered` is a no-op
alias on blocking/events). §C.4 below commits the 2D reconciliation conditional
on the experiment outcome.

**Default posture.** Option (a) — document and accept — pending experiment.
The architecture doc v1.1 already commits to "buffer valid for the duration
of the single `try await`". The experiment's job is to verify, not discover.

### Q3 — Listener / Connection API shape (gates 2A)

**Problem.** `Sockets.TCP.Listener` needs to hold an `IO` reference. Two
shapes are defensible:

| Shape | Call site |
|---|---|
| (a) One constructor taking any IO | `let listener = try Sockets.TCP.Listener(on: addr, io: IO.blocking())` |
| (b) Strategy-specific factories mirroring swift-io's | `let listener = try Sockets.TCP.Listener.blocking(on: addr)` / `.events(on: addr)` / `.completions(on: addr)` |

**Resolution criterion.** Write the 2A code under shape (a). If the call
site reads cleanly (no strategy concerns leak into `Listener`'s own API) and
the test for "multiple strategies on one listener type" passes, (a) is the
answer. If 2A's implementation reveals strategy-specific code paths inside
Listener (e.g., different accept loops per strategy), promote to (b) before
2B integrates the events-strategy path.

**Commit criterion.** 2A's final commit message names the shape and cites
the concrete call-site evidence.

## 3. Sub-phase Sequencing

```
2A — Validation spike (swift-sockets, blocking only, ~300 LOC, ~6 new files)
  └── Answers Q3; informs Q1 shape
  └── Ships production Listener/Connection + integration tests
  └── Gate: green tests on macOS (Linux-optional).

2B — Events refactor (~50 file-touches, 5 ordered steps)
  └── Step (i): migrate Bucket A (10 unambiguous) to swift-sockets
  └── Step (ii): resolve Bucket C (Storage, Storage.Alive, Receivers, Read, Write)
  └── Step (iii): write §B.3 Selector SPI decision → apply @_spi(ResourceBackend)
  └── Step (iv): internal IO.Events.Actor + IO.events(_:) factory
  └── Step (v): upgrade swift-sockets.TCPListener to events-strategy accept
  └── Each step: 1–N commits, one logical change per commit, no bundling.
  └── Gate: green tests on macOS for each commit; events-strategy accept
      proven by second integration test against real Selector.

2C — Completions refactor (~30 file-touches)
  └── Blocker: Q2 experiment written, committed to Research/
  └── Step (i): migrate Bucket A (Channel + Accept + Connect + Results)
      with Kernel.Socket.Descriptor type-correction on Accept.Result.
  └── Step (ii): write §C.3 Queue SPI decision → apply @_spi(ResourceBackend)
  └── Step (iii): internal IO.Completions.Actor + IO.completions(_:) factory
  └── Step (iv): upgrade swift-sockets for completions code path
  └── Gate: green tests on Linux (io_uring-dependent).

2D — IO.platformBest + polish (~10 file-touches)
  └── Blocker: §C.4 reconciliation if Q2 resolved with non-(a) outcome
  └── Step (i): IO.platformBest(_:) in IO umbrella, conditional dispatch
  └── Step (ii): buffer-ownership contract doc in IO.swift
  └── Step (iii): v1.0 ship-readiness sweep (tail latency note, multi-conn
      note, the deferred items called out in perf measurement doc)
  └── Gate: green tests on macOS AND Linux; doc renders clean.
```

### 3.1 Sequencing Rationale

The proposed ordering is 2A → 2B → 2C → 2D. This plan commits to it
unchanged after critical review of three alternatives:

1. **Q2 experiment earlier (parallel to 2A or 2B).** Rejected for
   critical-path purposes. The experiment's outcome only affects 2C/2D
   design; running it earlier does not compress the schedule. Where a
   parallel agent becomes available, 2B step (iii) is the natural hand-off
   point — the experiment is self-contained (~200 LOC) and can be scheduled
   any time before 2C step (i).

2. **2C before 2B.** Rejected. Events has larger scope (46 files vs 53, but
   more semantic mixing — Bucket C has 5 audit-required files in Events vs
   0 in Completions per author review §3). Doing Events first proves the
   cleanup pattern (migrate A, rescope C, apply SPI, wire actor, upgrade
   consumer) against the harder target; Completions then follows the same
   five-step recipe at lower risk. Reversing the order would have Events
   inherit any Completions-specific SPI quirks as defaults.

3. **2D split across phases (add `platformBest` incrementally).** Rejected.
   `platformBest` is a cross-strategy composition; it cannot exist until
   both events and completions factories exist. Splitting it forces a
   three-branch `#if`-conditional that rots between sub-phases.

The case FOR the proposed order:

- 2A delivers one thing: empirical evidence that the TCA26 shared-executor
  composition works in production code, with a concrete `Listener` shape
  that informs Q3. ~300 LOC is small enough to ship in one session and
  outlive Phase 2 as the reference-pattern regression test.
- 2B validates the refactor pattern on the harder of two targets; 2C inherits
  the pattern.
- 2D composes both; cheap once they exist; the Q2 reconciliation is the
  only new work.
- Every gate has a verification artifact: test pass, research doc written,
  code compiled.

## 4. Per-sub-phase Concrete Scope

### 4.A Phase 2A — Validation spike in swift-sockets

**Purpose.** Derisk the shared-executor composition with production code.
Answer Q3 empirically. Ship a regression test that guards against future
breakage.

**New files in swift-sockets** (all under `Sources/Sockets/`):

| File | Contents |
|---|---|
| `Sockets.TCP.swift` | `extension Sockets { public enum TCP {} }` — namespace. |
| `Sockets.TCP.Listener.swift` | `public actor Listener`. Holds `io: IO` + listener `Kernel.Socket.Descriptor`. Forwards `nonisolated var unownedExecutor` to `io.unownedExecutor`. Provides `accept() throws(Sockets.Error) -> Sockets.TCP.Connection` that runs on io's executor thread via actor isolation. |
| `Sockets.TCP.Connection.swift` | `public struct Connection: ~Copyable, Sendable`. Holds `descriptor: Kernel.Descriptor` (Path A, see §4.A.0), `peer: Kernel.Socket.Address.Storage`, `io: IO`. Delegates byte-level ops to io.read / io.write / io.close directly on the stored `Kernel.Descriptor`. |

**§4.A.0 Descriptor typing in Connection (Path A).**

`Sockets.TCP.Connection` stores `Kernel.Descriptor`, not `Kernel.Socket.Descriptor`.
The architecture doc v1.2 (at `TCP listener` example) documents this decision;
reproduced here for execution reference.

Two forces drove it:

1. **No public borrowing view exists.** `Kernel.Socket.Descriptor` has only a
   *consuming* conversion to `Kernel.Descriptor`
   (`Kernel.Descriptor(_: consuming Kernel.Socket.Descriptor)`). Day-to-day
   `io.read` / `io.write` / `io.close` calls demand a `borrowing Kernel.Descriptor`.
   Without a borrowing primitive, Connection cannot hold the typed form and still
   delegate to `io`.
2. **Ecosystem precedent.** `swift-io/Sources/IO Events/IO.Event.Channel.swift:60`
   already stores `Kernel.Descriptor?` for the same reason. Socket-specific
   syscall wrappers (`Kernel.Socket.getError`, `.shutdown`) accept
   `Kernel.Descriptor` overloads, so keeping the generic form does not block
   future socket-specific methods.

At the accept boundary, the socket descriptor is consumed into the generic form:

```swift
var result = try Kernel.Socket.Accept.accept(_fd)

// Kernel.Socket.Accept.Result is ~Copyable non-frozen; partial consumption
// is blocked across the iso-9945 module boundary. Swap-with-sentinel per
// swift-iso-9945/Research/frozen-accept-result.md until upstream @frozen lands.
var extracted = Kernel.Socket.Descriptor.invalid
Swift.swap(&result.descriptor, &extracted)

return Sockets.TCP.Connection(
    descriptor: Kernel.Descriptor(consume extracted),
    peer: result.address,
    io: io
)
```

The swap-with-sentinel workaround is acknowledged in-file with a `// WORKAROUND:`
comment per [PATTERN-016] referencing the iso-9945 tracking note.

**Escape hatch for Path B — deferred to when it's needed.** If a future
sub-phase surfaces a socket-specific op that genuinely requires the typed
`Kernel.Socket.Descriptor` form (no `Kernel.Descriptor` overload available),
the fix is a single-primitive addition: `Kernel.Socket.Descriptor.kernelDescriptor`
— a borrowing view via `_read { yield _fd }` on POSIX
(Windows needs a separate code path since `SOCKET` and `HANDLE` are distinct).
This would be a ~15-line extension in `swift-kernel-primitives` followed by
refactoring Connection to store `Kernel.Socket.Descriptor`. Not needed for
Phase 2A; §9 tracks it as an open item.

**Integration tests** (new `Tests/Sockets Tests/`):

1. `TCP.Listener.Echo.Tests.swift`: single-connection echo. Start a listener
   on a loopback ephemeral port; from a separate actor, connect, send N
   bytes, read them back, assert equality. Verifies end-to-end correctness
   of the shared-executor composition.
2. `TCP.Listener.MultipleConnections.Tests.swift`: accept three connections
   on one listener; echo round-trip on each. Documents the thread-per-IO
   serialization model — ALL connections share the one listener thread.
   This is the expected behavior, not a bug; the test's doc comment says so.

**Commit structure for 2A** (smallest atomic units; no bundling):

| # | Subject | Scope |
|---|---|---|
| 1 | `swift-sockets: add Sockets.TCP namespace` | `Sockets.TCP.swift` only. |
| 2 | `swift-sockets: add Sockets.TCP.Listener actor` | `Sockets.TCP.Listener.swift` + Package.swift additions if any (likely zero — deps unchanged). |
| 3 | `swift-sockets: add Sockets.TCP.Connection` | `Sockets.TCP.Connection.swift`. |
| 4 | `swift-sockets: add TCP echo + multi-connection integration tests` | Two new test files. |

Each commit: typed throws, `~Copyable` default, shared-executor pattern
via `io.unownedExecutor`, EINTR retry via POSIX wrappers in any syscall
shim swift-sockets adds. `Kernel.Socket.Accept.accept` lives in iso-9945
already.

**Verification gate for 2A.**

- `swift build` on both swift-io and swift-sockets — green (ask before
  running per user preference).
- `swift test` on swift-sockets — the two integration tests pass on macOS.
- Linux test run is best-effort; if a Linux runner is available, run it
  and document outcome. If not, note the gap and proceed.
- **2A final commit message names the Q3 answer** (shape (a) or (b)) with
  the concrete evidence from the call site.

**Out of 2A scope.** No accept on events strategy, no completions path, no
UDP, no IPv6 other than what the kernel layer hands back. Listener API is
TCP-blocking-only for 2A.

### 4.B Phase 2B — Events refactor

Five ordered steps. Each is a commit or small series.

#### 4.B.1 Step (i) — Migrate Bucket A (10 unambiguous files)

Source: `swift-io/Sources/IO Events/`. Destination: `swift-sockets/Sources/Sockets/`.

Files (per author review §3):

```
IO.Event.Channel.swift                      → Sockets.Events.Channel.swift (or equivalent)
IO.Event.Channel.HalfClose.State.swift      → Sockets.Events.Channel.HalfClose.State.swift
IO.Event.Channel.HalfClose.swift            → Sockets.Events.Channel.HalfClose.swift
IO.Event.Channel.Reader.swift               → Sockets.Events.Channel.Reader.swift
IO.Event.Channel.Writer.swift               → Sockets.Events.Channel.Writer.swift
IO.Event.Channel.Split.swift                → Sockets.Events.Channel.Split.swift
IO.Event.Channel.Shutdown.swift             → Sockets.Events.Channel.Shutdown.swift
IO.Event.Channel.Read.Result.swift          → Sockets.Events.Channel.Read.Result.swift
IO.Event.Channel.Write.Result.swift         → Sockets.Events.Channel.Write.Result.swift
IO.Event.Error+Channel.swift                → Sockets.Error+Channel.swift (or merged)
```

**Rename note.** The destination namespace is a decision to make during 2B
step (i). The spec-level choices are:

- **(A) `Sockets.Events.Channel`** — mirrors swift-io's `IO.Event.Channel`
  but under Sockets. Requires `Sockets.Events` namespace. Clear lineage.
- **(B) `Sockets.TCP.Channel`** — groups under the TCP namespace created in
  2A. Strategy-agnostic consumer API; events/completions distinction
  hidden by the factory.
- **(C) Per-strategy split** — `Sockets.Events.Channel` + `Sockets.Completions.Channel`
  separately. Explicit strategy exposure.

Choose (B) as the default — Channel is the consumer type; strategy is a
construction detail. This aligns with the TCA26 framing and avoids churn
if the strategy changes. Decision committed at this step with a
`// WHY:` comment in the first migrated file.

**Commit structure for step (i).** One commit per file-pair (source delete
+ destination add). Ten commits. Each commit:

- Preserves the type's semantics line-by-line.
- Updates imports: destination gets `public import Kernel` and
  `public import IO` (or narrower as needed per InternalImportsByDefault).
- Preserves argument labels per prior feedback memory
  (`feedback_preserve_labeled_api.md`).

Callers inside swift-io that referenced the migrated types (if any beyond
the Channel family itself) are updated to import the type from swift-sockets
or their references are removed. Grep-verify before each commit.

#### 4.B.2 Step (ii) — Resolve Bucket C

Per author review §3:

```
IO.Event.Channel.Read.swift          — 10-line namespace file. Moves with Channel (Bucket A).
IO.Event.Channel.Write.swift         — Same. Moves with Channel.
IO.Event.Channel.Storage.Alive.swift — Socket-specific alive-mask for split Reader/Writer. Moves to swift-sockets.
IO.Event.Channel.Storage.swift       — Reactor-generic core + socket-coupled split semantics. RENAME and retain internal, OR split.
IO.Event.Channel.Receivers.swift     — Reactor-generic bundling. RENAME and retain internal.
```

**Split decision for Storage.swift.** Author review recommends:

> Rename to `IO.Event.Registration.Storage`, drop alive-mask Reader/Writer
> concept (Channel's concern), OR move entirely to swift-sockets as
> `Sockets.Channel.Storage`.

This plan commits to **rename-and-keep-internal**: rename to
`IO.Event.Registration.Storage`, drop the alive-mask concept (which moves
with `Storage.Alive.swift` to swift-sockets), keep the descriptor-tracking
primitive internal to `IO Events`. Rationale: 2B step (iv)'s internal
`IO.Events.Actor` will need reactor-generic registration storage;
duplicating it in swift-sockets defeats the reason for keeping the runtime
at all.

**Rename for Receivers.swift.** Author review suggests `IO.Event.Receivers`
or `IO.Event.ReadinessEndpoints`. This plan commits to **`IO.Event.Receivers`**
— preserves the concept, drops the "Channel" association. Comment in the
renamed file links the old name for grep-ability.

**Commit structure for step (ii).** Five commits (one per file outcome).
Keep the renames isolated — don't bundle with unrelated edits.

#### 4.B.3 Step (iii) — Write §B.3 Selector SPI decision + apply annotation

**§B.3 subsection to write into this plan.** After step (ii), a
subsection is added here committing the Q1 answer (default: option (a)
`@_spi(ResourceBackend) public`), naming the exact retained-runtime files
that receive the SPI, and citing swift-sockets' concrete need from the
2A Listener code.

Expected SPI surface (default):

```
Selector.Register.swift          @_spi(ResourceBackend) public
Selector.Registration.swift      @_spi(ResourceBackend) public
Selector.Scope.swift             @_spi(ResourceBackend) public
Selector.Make.swift              @_spi(ResourceBackend) public (factory)
Runtime.swift                    @_spi(ResourceBackend) public (Runtime handle if swift-sockets needs to hold one)
Token.swift                      @_spi(ResourceBackend) public (register returns Token)
Interest+Hash.swift              @_spi(ResourceBackend) public (if Token uses Interest in its public surface)
```

All other retained runtime types stay `internal`. Per [MOD-016], every
consumer file in swift-sockets that references an SPI member must declare
its own `@_spi(ResourceBackend) import`. Count and document the SPI import
surface in swift-sockets' Package.swift and its file headers.

**Commit structure for step (iii).** One commit per SPI application site
(one per file, multiple imports per swift-sockets file get one commit).
Expect 5–10 commits.

#### 4.B.4 Step (iv) — Internal IO.Events.Actor + IO.events(_:) factory

**Files added** to `swift-io/Sources/IO Events/`:

| File | Role |
|---|---|
| `IO.Events.Actor.swift` | Internal actor wrapping the reactor runtime (`Selector`, `Runtime`, `Loop`). Exposes isolated `read` / `write` / `close` methods. Holds a `Kernel.Thread.Executor` (or the pool accessor, mirroring blocking's pattern at `IO.Blocking.Actor.swift`). Provides `unownedExecutor`. |
| `IO+Events.swift` | Factory extension on `IO`. Provides `IO.events(_:)` (picks a shared pool executor) and `IO.events(on:)` (pins to a caller-provided executor). Wires the four closures (`_read` / `_write` / `_close` / `_unownedExecutor`) to the actor's isolated methods. Error mapping from reactor runtime errors to `IO.Error` (analogous to `IO+Blocking.swift:78-109`). |

Error mapping rules (analogous to blocking):

| Reactor outcome | IO.Error case |
|---|---|
| Runtime is shutting down | `.shutdown` |
| Task cancelled | `.cancelled` |
| Read/Write returns EINTR after registered retries | (retried; no surface) |
| EPIPE on write | `.brokenPipe` |
| ECONNRESET on read | `.platform(code)` — accepting semantic loss per architecture doc §Rejected Designs row "Socket-specific Channel types" |
| Other POSIX errno | `.platform(code)` |

**Commit structure for step (iv).** Two commits:

1. Add `IO.Events.Actor` with isolated read/write/close; reactor
   plumbing internal.
2. Add `IO+Events.swift` factory + error mappings; wire closures.

#### 4.B.5 Step (v) — Upgrade swift-sockets' TCPListener to events-strategy accept

**What changes in swift-sockets.**

`Sockets.TCP.Listener` gains a code path: when the listener was constructed
with `IO.events(...)`, its `accept()` method:

1. Registers the listener fd with `IO.Event.Selector` via the
   `@_spi(ResourceBackend)` API from step (iii).
2. Awaits read-readiness (scoped to listener lifetime; deregistered on
   close).
3. Calls `POSIX.Kernel.Socket.Accept.accept` (non-blocking) when ready.
4. Returns the `Sockets.TCP.Connection`.

This proves the SPI surface is sufficient. If step (v) reveals the SPI is
under-sized (e.g., need `Selector.deregister` or `Token.cancel`), loop back
to step (iii), amend §B.3, and add the missing annotation. Document the
amendment in the §B.3 subsection's changelog.

**Integration test.** A third test, `TCP.Listener.Events.Echo.Tests.swift`,
mirrors 2A's echo test but constructs the listener with `IO.events(...)`.
This validates the full events-strategy path end-to-end.

**Commit structure for step (v).** One commit for the Listener upgrade
(adds the events-strategy branch inside `accept`), one commit for the new
integration test.

**Verification gate for 2B.** `swift build` green in both swift-io and
swift-sockets; all three integration tests pass (blocking, blocking-multi,
events); `swift test` green on macOS. Linux best-effort.

### 4.C Phase 2C — Completions refactor

**BLOCKER.** Do not start 2C step (i) until:

- The `Experiments/proactor-buffer-ownership/` experiment is written, run
  on Linux, and its conclusion committed to
  `Research/io-proactor-buffer-ownership.md`. This IS the Q2 resolution in
  writing.

Under the default posture (Q2 resolves with option (a)), 2C mirrors 2B's
five-step recipe at smaller scope.

#### 4.C.1 Step (i) — Migrate Bucket A

Per author review §3:

```
IO.Completion.Channel.swift        → Sockets.TCP.Channel.swift (or merged with Events-migrated Channel per step 2B.1 decision)
IO.Completion.Accept.swift         → Sockets.Completions.Accept.swift (or Sockets.TCP-scoped)
IO.Completion.Accept.Result.swift  → Sockets.Completions.Accept.Result.swift — **Gap 4: descriptor: Kernel.Descriptor → Kernel.Socket.Descriptor**
IO.Completion.Connect.swift        → Sockets.Completions.Connect.swift
IO.Completion.Connect.Result.swift → Sockets.Completions.Connect.Result.swift
```

**Gap 4 fix.** `IO.Completion.Accept.Result.descriptor` is currently
`Kernel.Descriptor`. On migration the type changes to
`Kernel.Socket.Descriptor`. This is a type correction, not just a move —
the commit message MUST flag it explicitly.

**Commit structure for step (i).** Five commits (one per file), plus one
for the Gap 4 type correction if it's not part of a file-migration commit.

#### 4.C.2 Step (ii) — Queue SPI decision (Q1')

**§C.3 subsection to write.** Parallel to §B.3. Commits the
`@_spi(ResourceBackend) public` annotation on:

```
Queue.swift               (Queue handle if swift-sockets holds one)
Queue.Scope.swift         (scope type)
Submit.swift              (submission entry)
Submit.Result.swift       (submission outcome)
Poll.Context.swift        (if swift-sockets needs to reach into poll state)
Operation.swift           (opcode enum; kept complete — exposing socket opcodes is policy, not necessity)
```

Rationale: swift-sockets submits `IORING_OP_ACCEPT` and `IORING_OP_CONNECT`
via `Queue.submit`. The public-submit path requires access to the `Queue`
handle and `Operation` enum.

**Commit structure for step (ii).** Analogous to 2B step (iii). One commit
per SPI application, expect 5–10 commits.

#### 4.C.3 Step (iii) — Internal IO.Completions.Actor + IO.completions(_:) factory

**Files added** to `swift-io/Sources/IO Completions/`:

| File | Role |
|---|---|
| `IO.Completions.Actor.swift` | Internal actor wrapping the proactor runtime. |
| `IO+Completions.swift` | Factory. `IO.completions(_:)` / `IO.completions(on:)`. Error mapping. |

Error mapping is analogous to 2B.4. Proactor-specific cases:

| Proactor outcome | IO.Error case |
|---|---|
| CQE `-EINTR` (rare under io_uring) | retried internally; no surface |
| CQE `-EPIPE` | `.brokenPipe` |
| CQE `-ECANCELED` | `.cancelled` |
| Ring shutdown | `.shutdown` |
| Other negative errno | `.platform(code)` |

**Commit structure for step (iii).** Two commits (actor, factory), same as
2B.4.

#### 4.C.4 Step (iv) — swift-sockets completions code path

swift-sockets' `Sockets.TCP.Listener` gains a completions-strategy branch
in `accept` that submits `IORING_OP_ACCEPT` via the `@_spi` Queue. Integration
test `TCP.Listener.Completions.Echo.Tests.swift` runs on Linux with io_uring
available.

**Commit structure for step (iv).** One commit for Listener upgrade; one
for the integration test.

**Verification gate for 2C.** All integration tests pass on Linux (macOS
skips completions tests). Buffer-ownership experiment's conclusion
document is committed to Research/.

### 4.D Phase 2D — IO.platformBest + polish

**Files added.**

| File | Contents |
|---|---|
| `swift-io/Sources/IO/IO+platformBest.swift` | Factory on `IO` in the umbrella product. Conditional dispatch: `#if os(Linux) → .completions()`, `#if canImport(Darwin) → .events()`, else → `.blocking()`. |
| `swift-io/Sources/IO/Package.swift` (update) | Ensure umbrella's `IO` target depends on IO Core, IO Blocking, IO Events, IO Completions. |

**Buffer-ownership contract.** Per Q2 resolution:

- **If (a)** — document in `IO.swift` doc comment: "Buffer validity guaranteed
  for the duration of the single `try await`, regardless of strategy.
  `platformBest` commits to the same contract."
- **If (b)** — `platformBest` chooses one side: expose ONLY `read`/`write`
  (kernel-copy-bridge on completions) OR expose `readRegistered`/
  `writeRegistered` (alias on blocking/events to plain read/write). The
  choice is committed in §C.4 during 2C.

**Commit structure for 2D.** Three commits:

1. Add `IO+platformBest.swift`.
2. Add buffer-ownership doc to `IO.swift`.
3. v1.0 ship-readiness sweep — doc comments in `IO.swift` surfacing the
   deferred items (tail latency, multi-connection contention, cancellation
   model) so consumers know what's not delivered.

**Verification gate for 2D.** Build green both platforms; `swift test`
green both platforms; doc comment render clean.

## 5. Commit Discipline (applies to ALL sub-phases)

- **Atomic.** One logical change per commit. Deletions and additions for a
  file migration are one commit when they're the same logical move; otherwise
  split.
- **Pre-flight every commit.** `git fetch --prune` in swift-io AND
  swift-sockets; `git log origin/main..HEAD` should contain only this
  session's work. Flag any external commits immediately. Parallel sessions
  have historically landed mid-phase (660c14c7, 9db824cc, c83e3885); the
  pattern can recur.
- **Ask before `swift build` / `swift test`.** Per user preference
  (`feedback_ask_before_build_test.md`).
- **Never skip hooks / bypass signing / amend published commits / force-push.**
- **Typed throws everywhere.** No `throws` without `(E)`. Catch blocks
  preserve concrete error type per [IMPL-075] / [API-ERR-004].
- **`~Copyable` as default posture** per [IMPL-064]. Justify every `Copyable`.
- **Shared-executor pattern via `unownedExecutor` forwarding** is the
  canonical production pattern; document any default-path fallback.

## 6. Out of Scope for Phase 2

The following items are deferred beyond Phase 2. Each has a trigger or
phase for re-entry.

| Item | Trigger / phase |
|---|---|
| Cancellation + timeout composition through blocking thread syscalls (`pthread_kill(SIGUSR2)`), events-poll exit, completions `IORING_OP_ASYNC_CANCEL` | Phase 5+ |
| swift-file-system bootstrap (`pread`, `pwrite`, `preadv`, `pwritev`, `openat`, `mmap`, `xattr`, `stat`, `statfs`) | Separate package, separate plan |
| swift-pipes (`splice`, `tee`, `sendfile`) | If/when built; may never |
| UDP datagrams (`sendmsg` / `recvmsg` on `Sockets.UDP`) | swift-sockets Phase 2+ (post this Phase 2) |
| DNS resolution | swift-sockets composition with a resolver package |
| TLS integration | Separate package; composes with swift-sockets |
| Linux cgroup / namespace isolation | Separate Foundations package |
| Windows IOCP strategy | Separate Phase (Windows stack maturity) |
| `p99` / `p99.9` tail latency characterization | Pre-v1.0 ship-readiness |
| Multi-connection contention benchmark (N consumers sharing one IO executor thread) | Pre-v1.0 ship-readiness |
| Network-syscall re-measurement (TCP loopback / socketpair) | Pre-v1.0 ship-readiness; strengthens shared-executor case |
| Hand-written IO as alternative to `@Witness` | Phase 2 reassessment trigger: ≥3-of-5 manual forwards on new witness |

## 7. Rejected Framings (historical; do NOT rebuild without new evidence)

Every entry below was considered, debated in the five prior sessions'
handoffs, and rejected. Re-opening any requires written evidence.

| Framing | Why rejected | Reference |
|---|---|---|
| `IO.Socket` witness in swift-io (accept on the IO witness) | Domain-authority violation; accept is socket-specific. Reverted via commit `1a1d7123`. | io-architecture.md §Rejected Designs; HANDOFF-io-layered-implementation.md §Dead Ends |
| `swift-io-primitives` L1 split | YAGNI. `@Witness` macro is L3 (loses `unimplemented()`/`observe`/`Calls`). No consumer needs IO without the blocking impl. | io-architecture.md §Rejected Designs |
| Framing B — context-oriented primitives (`IO.Blocking.Executor` / `IO.Events.Runtime` / `IO.Completions.Runtime` as public concrete types) | Performance rationale collapsed when TCA26 measured at 0.95× raw syscall cost. Architectural alternative remains on the table but no forcing function. | io-performance-ceiling-measurement.md §Decision |
| Framing C — dual public API (witness + contexts both public) | Documentation burden; two ways to do everything; no evidence a user wants both. | HANDOFF-io-layered-implementation-review.md §Framing C |
| Framing E — `IO.Event.Channel` as swift-io public Tier 1+ API | Socket-specific ergonomics belong in swift-sockets, not swift-io. Fate-doc committed to deletion. | io-architecture.md §Rejected Designs |
| `IO.Completion.Channel` as swift-io public type | Same reasoning. | io-architecture.md §Rejected Designs |
| Context / Stream / Reader / Writer / Run types (pre-Shape-B scaffolding) | Superseded by the 4-closure witness. Deleted in Phase 1 commit `c428efac`. | io-architecture.md §Rejected Designs; HANDOFF-io-layered-implementation.md §Current Tree State |
| Raw syscalls without EINTR retry | Surfaces spurious `.platform(EINTR)` to consumers for no benefit. POSIX wrappers (`POSIX.Kernel.IO.Read.read` / `POSIX.Kernel.IO.Write.write`) retry internally. | io-architecture.md §POSIX Wrapper Policy |
| `any SerialExecutor` on public types | Breaks embedded Swift compatibility. Concrete executor types only. | io-architecture.md §Rejected Designs |
| Admission gating / dispatch API (pre-Shape-B) | Backpressure via actor queue; admission was a dispatch-layer artifact. Deleted via external commits `660c14c7` + `9db824cc`. | HANDOFF-io-phase-1-author-review.md §Step 3 — DONE |
| `Actor.run` fast path as public API | Forces `@Sendable` body; consume-into-body breaks for `~Copyable` descriptors. | io-architecture.md §Rejected Designs |
| `sending` + `isolated Self` closure body | Swift 6.3 region-checker limitation — does not compile. | io-architecture.md §Rejected Designs |
| Force-adding root `HANDOFF-*.md` to tracked tree | gitignore policy; handoffs stay local. Research/ is tracked. | HANDOFF-io-layered-implementation.md §Constraints |

## 8. Supporting Evidence

### 8.1 Benchmarks

- `swift-io/Experiments/io-stacked-actor-bench/` — 4-config benchmark
  validating TCA26 at 0.95× raw syscall cost. Source + `RESULTS.md`.
- `swift-io/Experiments/actor-hop-benchmark/` — precedent no-op hop cost
  (~3.9 µs). Pre-TCA26 measurement.

### 8.2 Research

- `Research/io-architecture.md` v1.1 — CANONICAL. Domain-agnostic swift-io,
  four-closure witness, strategy-per-factory, socket-code-in-swift-sockets.
- `Research/io-performance-ceiling-measurement.md` — methodology + findings
  backing the shared-executor positioning.

### 8.3 Operational Handoffs (local per gitignore)

- `HANDOFF-io-layered-implementation.md` — Phase 1 spec + bucket hints for
  Phase 2.
- `HANDOFF-io-phase-1-author-review.md` — tree verification, Bucket A/B/C
  classification, Gaps 1–10 (relevant: Gap 3 events-accept, Gap 4
  Accept.Result descriptor type, Gap 5 runtime visibility).
- `HANDOFF-io-layered-implementation-review.md` + `-response.md` — design
  debate. Framings A–E considered; Framing E committed.
- `HANDOFF-io-performance-measurement-response.md` — performance gate
  clearance.

### 8.4 Cross-repo references

- `swift-iso-9945/Research/frozen-accept-result.md` — `Kernel.Socket.Accept.Result`
  `@frozen` follow-up + swap-with-sentinel workaround. Referenced at 2A
  step 3 in-file comment.
- Swift Institute skills: code-surface ([API-NAME-001] through
  [API-IMPL-011]), implementation ([IMPL-*] especially [IMPL-INTENT],
  [IMPL-064], [IMPL-066]–[IMPL-070]), modularization ([MOD-DOMAIN],
  [MOD-016] SPI per-file opt-in), platform ([PLAT-ARCH-*] for domain
  authority framing that motivates socket-code-outside-swift-io).

## 9. Open Items Deliberately NOT Decided Here

These are items where this plan declines to commit pending earlier work:

- **§B.3 Selector SPI decision** — written at 2B step (iii).
- **§C.3 Queue SPI decision** — written at 2C step (ii).
- **§C.4 platformBest buffer-ownership reconciliation** — written at 2C
  step (i) conditional on Q2 experiment outcome.
- **Sockets.TCP.Channel vs Sockets.Events.Channel naming** — committed at
  2B step (i) first file-migration commit; default (B) `Sockets.TCP.Channel`.
- **Linux test environment availability** — flagged at 2A; if absent,
  2C is blocked pending resolution (io_uring is Linux-only).
- **`Kernel.Socket.Descriptor.kernelDescriptor` borrowing view** — Path B
  escape hatch per §4.A.0. Defer to swift-kernel-primitives when a socket-
  specific op that requires the typed form appears in 2B or later (none
  currently identified). The addition is ~15 lines and local to
  `Kernel.Socket.Descriptor.swift`; migrating Connection from `Kernel.Descriptor`
  to `Kernel.Socket.Descriptor` at that point is a Connection-local refactor.

## 10. First Action After Plan Approval

On user acknowledgment of sequencing (or redirection), 2A starts with:

1. Pre-flight `git fetch --prune` + `git log origin/main..HEAD` in both
   swift-io and swift-sockets.
2. Sockets.TCP namespace commit — `Sockets.TCP.swift`.

2A is scoped to stop at the verification gate (both integration tests
pass). 2B does NOT start automatically; user review of 2A informs Q1 and
Q3 resolutions that shape 2B.
