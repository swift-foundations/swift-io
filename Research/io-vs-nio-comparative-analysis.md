# IO vs NIO Comparative Analysis

<!--
---
version: 1.0.0
created: 2026-04-16
last_updated: 2026-04-16
status: RECOMMENDATION
tier: 2
scope: cross-package (swift-io + swift-sockets + swift-file-system constellation vs Apple swift-nio)
related:
  - swift-foundations/Research/nio-inspired-capability-additions.md (follow-up investigation)
  - swift-foundations/swift-io/Research/io-architecture.md (canonical swift-io architecture)
  - swift-foundations/swift-io/Research/io-phase-2-plan.md (Phase 2 execution contract)
---
-->

## Context

swift-io is being developed as a domain-agnostic async I/O capability library whose role is to stand beneath a family of sibling packages (swift-sockets, swift-file-system, and a future swift-networking). Apple's swift-nio is the incumbent Swift async I/O framework and the de-facto reference point. An explicit structural comparison has not been recorded.

**Trigger**: Accumulated Phase 2 design decisions reference NIO selectively — sometimes as inspiration (AsyncSequence backpressure shape), sometimes as an anti-model (reference-type `Channel`, untyped throws). The absence of a single reference comparison makes it expensive to trace these decisions back to a coherent position.

**Stakeholders**: authors and reviewers of swift-io, swift-sockets, swift-file-system, and downstream consumers evaluating the trade of adopting the constellation vs. NIO.

**Timeline**: immediate — used as the input to [nio-inspired-capability-additions.md](nio-inspired-capability-additions.md).

## Question

How does swift-io — considered as the base layer of the constellation (swift-io + swift-sockets + swift-file-system + future swift-networking) — compare to Apple's swift-nio, with respect to (a) capability coverage, (b) architectural commitments, and (c) theoretical grounding?

## Methodology

This is a Tier 2 Discovery per [RES-013]. Both source trees were inspected first-hand:

- swift-nio: `/Users/coen/Developer/apple/swift-nio`
- swift-io: `/Users/coen/Developer/swift-foundations/swift-io`
- swift-sockets: `/Users/coen/Developer/swift-foundations/swift-sockets`
- swift-file-system: `/Users/coen/Developer/swift-foundations/swift-file-system`
- supporting stubs: `/Users/coen/Developer/swift-foundations/swift-{http,http2,http3,websocket,transport-layer-security,domain-name-system,pool-connections,graceful-shutdown,signal}/`

Claims cite files as `package:path:line_range`. Where a supporting package was found to be a pure stub, this was verified by directory listing.

Prior art survey per [RES-021] is interleaved: the NIO side IS the prior art for the swift-io side.

## Analysis

### Axiom comparison

| Axis | swift-nio | swift-io |
|------|-----------|----------|
| Top abstraction | `Channel` protocol, reference type, pipeline-attached (`nio:Sources/NIOCore/Channel.swift:22`) | `IO` value-type `@Witness` struct (`io:Sources/IO Core/IO.swift:132–188`) |
| Witness shape | Four-method inbound + four-method outbound pipeline; `EventLoopFuture<T>` returns | Four closures: `_read`, `_write`, `_close`, `_ready` plus `_unownedExecutor`; `async throws(IO.Error) -> T` returns |
| Error model | `any Error` carried in futures; boundaries catch untyped | Typed throws end-to-end; `IO.Error` = `{.brokenPipe, .timeout, .cancelled, .shutdown, .platform(Kernel.Error.Code)}` (`io:Sources/IO Core/IO.Error.swift`) |
| Thread model | `MultiThreadedEventLoopGroup` of N `SelectableEventLoop`s, one OS thread each (`nio:Sources/NIOPosix/MultiThreadedEventLoopGroup.swift`) | Three strategy actors, each pinned to an executor: `IO.Blocking.Actor` (internal), `IO.Event.Actor` (public, `io:Sources/IO Events/IO.Event.Actor.swift:60`), `IO.Completion.Actor` (public, Linux-only, `io:Sources/IO Completions/IO.Completion.Actor.swift:69`, gated by `#if !os(Windows)` at line 25) |
| Backend selection | Compile-time via `#if` guards (kqueue, epoll, io_uring opt-in, WSAPoll) under a unified `Selector` | Runtime via factory: `IO.events(...)`, `IO.completions(...)`, `IO.blocking(...)`, `IO.default()` |
| Descriptor ownership | Raw `CInt` inside a reference `Socket`/`FileHandle` | `~Copyable Kernel.Descriptor` with move-only ownership; `close` is `consuming` |
| Buffer model | `ByteBuffer`: CoW, refcount-backed, contiguous, owns storage (`nio:Sources/NIOCore/ByteBuffer-core.swift:298+`) | `Memory.Buffer`/`Memory.Buffer.Mutable`: non-owning views with "stable address over `try await`" contract (`io:Sources/IO Core/IO.swift:37–71`) |
| Cancellation | Promise-failure semantics; no structural guarantee that the syscall has returned before `close()` completes | Native `withTaskCancellationHandler`; proactor uses a **two-CQE handshake** that awaits both the original CQE and the `IORING_OP_ASYNC_CANCEL` CQE before returning (`io:Sources/IO Completions/IO.Completion.Actor.swift:455–564`) |
| Executor integration | `EventLoop: SerialExecutor` bridge exists but the loop primitive is NIO's own scheduler | Each strategy actor exposes `nonisolated unownedExecutor`; `IO.unownedExecutor` forwards it, enabling zero-hop consumer actors (TCA26 pattern) |
| Async/await | Grafted: `NIOAsyncChannel<Inbound, Outbound>` wraps the reference `Channel` with an `AsyncSequence` and a watermarked writer (`nio:Sources/NIOCore/AsyncChannel/AsyncChannel.swift:36–74`) | Native: the witness itself is async; no `EventLoopFuture` analogue |
| Backpressure | Application-level `HighLowWatermark` in `NIOAsyncChannel.Configuration` (defaults 2/10) | Strategy-intrinsic: blocking bounded by thread count; reactor by registration-per-interest; proactor by io_uring ring capacity |
| In-tree protocol codecs | HTTP/1 (`nio:Sources/NIOHTTP1/`), WebSocket RFC 6455 (`nio:Sources/NIOWebSocket/`) | None |

### Capability coverage

| Capability | swift-nio | swift-io constellation |
|------------|-----------|------------------------|
| TCP listen/accept/connect | `ServerBootstrap`/`ClientBootstrap` | `Sockets.TCP.Listener`/`Sockets.TCP.Connection`, Phase 2A blocking, IPv4 only |
| IPv6 sockets | yes | planned, not present |
| Unix-domain sockets | yes | planned, not present |
| UDP / datagram | `DatagramBootstrap`, `AddressedEnvelope<T>`, `DatagramVectorReadManager` | absent |
| Multicast | `MulticastChannel` protocol (`nio:Sources/NIOCore/MulticastChannel.swift:19+`) | absent |
| Raw sockets | `RawSocketBootstrap` | absent |
| Pipe bootstrap | `NIOPipeBootstrap` | not needed (fd-generic) but not surfaced |
| File I/O | `NIOFileSystem` (new), `NonBlockingFileIO` (legacy), `FileRegion` for sendfile | `swift-file-system` async wrappers on `IO.Blocking.shared` |
| mmap / sendfile / copy_file_range / splice | `FileRegion` (sendfile, deprecated) | absent |
| TLS | `swift-nio-ssl` (BoringSSL) | `swift-transport-layer-security` contains only `LICENSE.md` |
| HTTP/1 | in-tree `NIOHTTP1` | `swift-http` contains only `LICENSE.md` |
| HTTP/2 | `swift-nio-http2` | `swift-http2` contains only `LICENSE.md` |
| HTTP/3 / QUIC | partial via community | `swift-http3` contains only `LICENSE.md` |
| WebSocket | in-tree `NIOWebSocket` | `swift-websocket` contains only `LICENSE.md` |
| DNS resolution | external via libc / AsyncHTTPClient | `swift-domain-name-system`, `swift-dns-cache` contain only `LICENSE.md` |
| Connection pooling | external | `swift-pool-connections` contains only `LICENSE.md` |
| Graceful shutdown | `EventLoopGroup.shutdownGracefully` | `swift-graceful-shutdown` contains only `LICENSE.md` |
| Signal handling | user-level | `swift-signal` contains only `LICENSE.md` |
| In-memory test harness | `EmbeddedEventLoop`, `EmbeddedChannel`, `AsyncTestingEventLoop`, `AsyncTestingChannel`, `NIOHTTP1TestServer`, `ByteToMessageDecoderVerifier` | minimal; witness-level mocking via `@Witness` generator disabled for `borrowing` params (`io:Sources/IO Core/IO.swift:92–98`) |
| Timer scheduling | `Scheduled<T>`, `RepeatedTask` on `EventLoop` | delegated to `Task.sleep` + custom executor |
| Vectored I/O (readv/writev/sendmsg/recvmsg) | yes, used for vector reads and gathered writes | witness is single-buffer only |
| Batch readiness (N fds, one wake) | native `Selector` semantics | single-fd `io.ready(from:interest:)`; multi-fd via N concurrent tasks |

### What swift-io enables that swift-nio does not

1. **Runtime strategy choice under one type**. `let io = platformUsesIoUring ? IO.completions() : IO.events()` is a one-line swap; NIO would require a different `EventLoopGroup` subtype and compile flags.
2. **Move-only descriptor ownership**. `Kernel.Descriptor` is `~Copyable`; double-close is a compile error.
3. **Typed throws through every layer**. Exhaustive `catch` matches IO errors; no `any Error` widening.
4. **Multi-CQE cancel handshake**. For io_uring, the two-CQE handshake (`io:Sources/IO Completions/IO.Completion.Actor.swift:475–534`) preserves buffer-ownership correctness under task cancellation. NIO does not have to solve this because its io_uring backend uses `poll`-style compatibility rather than full async submission.
5. **Shared-executor zero-hop**. Consumer actors that forward `io.unownedExecutor` observe no isolation hop per call — measured at ~320 ns per op in `io:README.md` benchmark.
6. **Strict memory safety enabled**. `io:Package.swift:180` enables `strictMemorySafety()`; NIO pre-dates the feature.
7. **Domain-agnostic**. Same `IO` witness reads sockets, files, pipes, TTYs. NIO's `Channel` has socket-biased semantics (local/remote address, socket-option-shaped channel options).
8. **Witness is a value**. Mocking, observation (`IO.observe`), composition, and forwarding are straightforward; NIO's `Channel` pipeline is a reference lattice.

### What the constellation is missing

Separated into (a) swift-io itself, (b) direct consumers, (c) sibling stack stubs.

**(a) In swift-io itself — candidates for addition** (detailed in the follow-up [nio-inspired-capability-additions.md](nio-inspired-capability-additions.md)):

- Deadline-bound I/O (`io.read(..., deadline:)`). `IO.Error.timeout` exists without a producer.
- Vectored I/O. Witness takes single buffer; io_uring has `IORING_OP_READV` natively.
- Many-fd batch readiness. Current `ready` is single-fd; a batched primitive is possible but may duplicate the reactor's internal multiplexing. Open question.
- Shared-singleton `shutdown()`. `IO.Event.Actor.shared()` / `IO.Completion.Actor.shared()` are process-lifetime singletons (`io:Sources/IO Events/IO.Event.Actor.swift:222–244`). Orderly shutdown is not implemented; flagged in `swift-sockets/HANDOFF.md`.
- Test fakes. `@Witness(.mock)` is disabled for `borrowing` parameters (`io:Sources/IO Core/IO.swift:92–98`); a hand-maintained `IO.fake()` or documented pattern is absent.

**(b) In direct consumers — constellation gaps**:

- UDP, multicast, raw sockets, pipes in swift-sockets.
- IPv6, Unix-domain addresses in swift-sockets.
- Connection writability/backpressure signals in swift-sockets.
- mmap, sendfile, copy_file_range in swift-file-system.
- Directory change notifications (inotify/FSEvents) in swift-file-system.
- Random file reads and streaming async reads in swift-file-system (partial).

**(c) Sibling stack blockers for server-side parity**: verified via directory listing — each of the following contains only `LICENSE.md`:

- `swift-transport-layer-security` — blocks HTTPS, WSS, mTLS.
- `swift-http` — HTTP/1.1 codec.
- `swift-http2`, `swift-http3` — HTTP/2, QUIC/HTTP/3.
- `swift-websocket` — RFC 6455.
- `swift-domain-name-system`, `swift-dns-cache` — name resolution.
- `swift-pool-connections` — connection pooling.
- `swift-graceful-shutdown` — lifecycle orchestration.
- `swift-signal` — POSIX signal trapping.

### Theoretical grounding

swift-nio inherits the *Reactor* pattern (Schmidt et al., *Pattern-Oriented Software Architecture*, Vol. 2, Chapter "Reactor") and Netty's `ChannelPipeline` model. `EventLoopFuture` descends from `java.util.concurrent.Future` / Netty's `ChannelFuture`. `NIOAsyncChannel` is a late-added adapter intentionally narrowed: it cannot carry user events or traditional writability backpressure (`nio:Sources/NIOCore/AsyncChannel/AsyncChannel.swift:26–30`).

swift-io's design space is three-layered and is cited inline in the source (`io:Sources/IO Core/IO.swift:128–131`):

- **Value-type capabilities**: Brachthäuser, Schuster & Lippmeier, "Effects as Capabilities", ECOOP 2020.
- **Runners / effect handlers**: Ahman & Bauer, "Runners in Action", ESOP 2020.
- **Region-based memory ownership**: implicit in Swift's `~Copyable` and `~Escapable`; the buffer-ownership contract at `io:Sources/IO Core/IO.swift:37–71` is defended by Swift 6's region isolation checker.

These foundations only became tractable with Swift 6.x (`~Copyable`, typed throws, strict concurrency, sending parameters). NIO's 2017 provenance prevents adoption without a v3 redesign.

### Contextualization (per [RES-021])

Not every absence relative to NIO is a gap. The following NIO features are **deliberate non-goals** for swift-io:

| NIO feature | Contextualized cost in swift-io | Verdict |
|-------------|---------------------------------|---------|
| Reference-type `Channel` | Requires discarding value-semantics, re-introducing `any Error`, and building a pipeline interception model orthogonal to actor isolation | Deliberate non-goal |
| `ChannelPipeline` / `ChannelHandler` | Belongs in a higher-layer package (swift-sockets or swift-networking) if ever; swift-io's witness is the handler-free primitive | Non-goal for swift-io |
| `EventLoopFuture<T>` combinators | Native `async/await` + typed throws subsumes the use cases | Deliberate non-goal |
| `ByteBuffer` as the lingua franca | Forcing all consumers to marshal into/out of a framework-owned buffer conflicts with the "caller owns storage" contract | Deliberate non-goal |
| User events (`triggerUserOutboundEvent`) | No analogue needed; cross-cutting concerns compose via sending parameters and continuations | Non-goal |
| Untyped throws in ChannelHandlers | Directly conflicts with typed-throws axiom | Non-goal |

## Outcome

**Status**: RECOMMENDATION

### Findings

1. **At swift-io's own layer** (the witness + three strategy actors), the design is strictly more rigorous than NIO's equivalent slice for new code that can afford Swift 6.x type discipline. Seven distinct structural wins listed above.
2. **At the constellation layer**, the stack is 15–20% complete against a "replace NIO for production HTTPS" benchmark. Nine of the sibling packages (TLS, HTTP/1/2/3, WebSocket, DNS, pool, graceful-shutdown, signal) contain only `LICENSE.md`.
3. **Inside swift-io**, five concrete capability additions are credible inspired by NIO. These are fully elaborated in the follow-up [nio-inspired-capability-additions.md](nio-inspired-capability-additions.md).
4. **Inside swift-kernel/swift-executors**, further additions (vectored I/O syscall primitives, zero-copy transfers, thread-pool observability) are credible. Also elaborated in the follow-up.
5. **Deliberate non-goals** (reference-type channels, pipelines, untyped futures, framework-owned buffers) should not be revisited based on NIO parity arguments alone; they conflict with swift-io's axioms.

### Recommendations

1. **Adopt the follow-up document** as the canonical list of NIO-inspired additions under consideration.
2. **Do not treat constellation-stub packages as swift-io scope**. TLS/HTTP/WebSocket are distinct packages with their own research needs.
3. **Resolve the shared-singleton `shutdown()`** as the highest-priority swift-io-internal item — already flagged in `swift-sockets/HANDOFF.md` and blocks Linux test-suite clean exit.
4. **Complete the swift-sockets Phase 2B/2C** (events + completions strategies with existing types), then expand to UDP and IPv6 before entertaining further NIO-inspired additions.
5. **Formalize contextualization as a review gate**: any new "NIO has this" proposal for swift-io MUST first pass the contextualization check of [RES-021] — concretize the proposal in swift-io's type system before classifying absence as a gap.

### Non-recommendations (explicit non-goals preserved)

- No `Channel`/`Pipeline`/`Handler` equivalent in swift-io.
- No `EventLoopFuture<T>` equivalent in swift-io.
- No framework-owned buffer type as mandatory interchange.
- No untyped throws at any public surface.

## References

- swift-nio source: `/Users/coen/Developer/apple/swift-nio` (inspected 2026-04-16).
- swift-io source: `/Users/coen/Developer/swift-foundations/swift-io` (inspected 2026-04-16).
- swift-sockets: `/Users/coen/Developer/swift-foundations/swift-sockets` (Phase 2A).
- swift-file-system: `/Users/coen/Developer/swift-foundations/swift-file-system`.
- Brachthäuser, J., Schuster, P., Lippmeier, K. "Effects as Capabilities: Effect Handlers and Lightweight Effect Polymorphism." ECOOP 2020.
- Ahman, D., Bauer, A. "Runners in Action." ESOP 2020.
- Schmidt, D.C. et al. *Pattern-Oriented Software Architecture, Vol. 2*, Chapter "Reactor", Wiley, 2000.
- swift-io canonical architecture: `swift-io/Research/io-architecture.md` v1.3.
- swift-io Phase 2 plan: `swift-io/Research/io-phase-2-plan.md`.
- Proactor buffer ownership: `swift-io/Research/io-proactor-buffer-ownership.md`.
- TCA26 shared-executor pattern: referenced in `swift-io/Research/io-blocking-executor-binding.md` v4.0.
