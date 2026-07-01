# swift-io Perfect API

> # ⚠️ INTENT, NOT STATUS — DO NOT CITE TYPE NAMES FROM THIS DOC
>
> This document is a **design recommendation from 2026-04-08**. Its Tier 0
> and Tier 1+ tables describe an *intended* API surface. **Most types
> listed do not exist in `Sources/`.** Verify every type against
> `Sources/` before citing it in code, research notes, or downstream
> packages. Reading this doc as inventory has caused multiple regressions
> across this repo and at least one downstream package
> (swift-file-system).
>
> **Authoritative sources for current API:**
> - `Sources/IO Core/IO.swift:133` — the `IO` witness (4 closures + executor)
> - `Sources/IO Events/README.md` — events strategy (full conceptual model)
> - `Sources/IO Completions/README.md` — completions strategy
> - `Sources/IO Blocking/README.md` — blocking strategy
> - `Research/README.md` — corpus entry point with anti-patterns
> - `Research/swift-io-thesis.md` — current thesis
>
> **Notable types in this doc that no longer exist** (deleted by the
> 2026-04-14 strict-mission refactor or never implemented):
> - `IO.run`, `IO.Run`, `IO.Run.Blocking` — deleted; no replacement in swift-io
> - `IO.run.blocking { body }` — moved to `Kernel.Thread.Pool.run { body }` in **swift-threads**
> - `IO.Blocking.Error` — replaced by `Kernel.Thread.Pool.Error` in swift-threads
> - `IO.Event.Driver`, `IO.Event.{Channel, Selector, Token}` — never landed; `IO.Event.Actor` is the implementation
> - `IO.Completion.Driver`, `IO.Completion.Queue`, `IO.Completion.{Read, Write, Accept, Connect}` — never landed; `IO.Completion.Actor` + `IO.Completion.Entry` is the implementation
> - `IO.Reader`, `IO.Writer`, `IO.Stream`, `IO.Context` — listed as planned; not implemented; the witness uses fd-direct ops
>
> The doc is preserved as **design history** — the thinking that led to
> the current witness shape — not as an implementation reference.

---

<!--
---
version: 3.0.0
created: 2026-04-08
status: RECOMMENDATION
supersedes:
  - theoretical-perfect-io-api.md
  - io-events-perfect-public-api.md
  - api-comparative-analysis.md
  - executor-first-architecture.md
  - executor-lifecycle-architecture.md
  - perfect-lifecycle-design.md
  - synchronous-run-overload.md
  - thread-ownership-lifecycle-refactor.md
  - tier-0-consumer-api-review.md
---
-->

## Architecture

Five targets. One consumer import.

```
IO Core         (internal)   Namespace + re-exports
IO Blocking     (Tier 0)     Dedicated thread pool
IO Events       (Tier 1+)    Reactor: Channel, Selector, Driver
IO Completions  (Tier 1+)    Proactor: Queue, Driver, operations
IO              (Tier 0)     Consumer API: run, read, write, Stream, Error
```

`import IO` gives Tier 0. `import IO_Events` or `import IO_Completions` gives Tier 1+.

---

## Tier 0: Consumer API

Three words: `IO.run`, `IO.read`, `IO.write`. The consumer never constructs
a Stream, Context, Buffer, Selector, or Channel.

### IO.run — the universal entry point

```swift
// Single-stream I/O — one closure, both halves
try await IO.run(socket) { reader, writer in
    try await writer.write(all: request)
    try await reader.forEach { chunk in
        process(chunk)
    }
}

// Multi-stream runtime — shared selector
try await IO.run { io in
    try await IO.run(socketA, in: io) { readerA, writerA in ... }
    try await IO.run(socketB, in: io) { readerB, writerB in ... }
}

// Blocking work — async (await → T)
let hash = try await IO.run.blocking { computeHash(data) }

// Blocking work — sync (no await → Handle<T>)
let handle = IO.run.blocking { computeHash(data) }
let result = try await handle.value()
```

Three overloads on `IO.Run.callAsFunction`:

| Call site | Overload | Selected by |
|-----------|----------|-------------|
| `IO.run(socket) { reader, writer in }` | Single-stream | First arg is `Kernel.Descriptor` |
| `IO.run { io in }` | Multi-stream runtime | Closure takes `IO.Context` |
| `IO.run.blocking { }` | Blocking work | Property chain `.blocking` |

### IO.read / IO.write — one-shot convenience

```swift
// Read all bytes from a descriptor
let data = try await IO.read(from: socket)

// Write bytes to a descriptor
try await IO.write(to: socket, data: bytes)
```

Sugar over `IO.run(descriptor) { reader, writer in ... }`.

### IO.run.blocking — sync/async via language

Swift disambiguates by async context:

```swift
// Has `await` → async overload → returns T
let hash = try await IO.run.blocking { computeHash(data) }

// No `await` → sync overload → returns Handle<T>
let handle = IO.run.blocking { computeHash(data) }
let result = try await handle.value()
```

No separate API for sync vs async. The language IS the API.

---

## Consumer Patterns

### Echo server

```swift
try await IO.run(socket) { reader, writer in
    try await reader.forEach { chunk in
        try await writer.write(all: chunk)
    }
}
```

### HTTP-style request/response

```swift
try await IO.run(socket) { reader, writer in
    try await writer.write(all: request.bytes)
    try await writer.shutdown()              // FIN — done writing
    let response = try await reader.readAll()
    return response
}
```

### Full-duplex with concurrent tasks

```swift
try await IO.run(socket) { reader, writer in
    async let readDone: Void = {
        try await reader.forEach { chunk in handle(chunk) }
    }()
    try await writer.write(all: payload)
    try await writer.close()
    try await readDone
}
```

### Pipe (forward all bytes)

```swift
try await IO.run { io in
    try await IO.run(source, in: io) { srcReader, _ in
        try await IO.run(sink, in: io) { _, sinkWriter in
            try await srcReader.pipe(to: &sinkWriter)
        }
    }
}
```

### File read

```swift
let contents = try await IO.read(from: fileDescriptor)
```

### Blocking syscall

```swift
let stat = try await IO.run.blocking {
    try Kernel.File.stat(path)
}
```

---

## Type Inventory

### Tier 0 — `import IO`

| Type | Conformances | Purpose |
|------|-------------|---------|
| `IO.Run` | Sendable | Entry point struct (callAsFunction overloads) |
| `IO.Run.Blocking` | — | Tag for `.blocking` sub-accessor |
| `IO.Read` | — | Tag for `.read` convenience accessor |
| `IO.Write` | — | Tag for `.write` convenience accessor |
| `IO.Stream` | ~Copyable, Sendable | Bidirectional byte stream (internal to IO.run) |
| `IO.Reader` | ~Copyable, Sendable | Read half |
| `IO.Writer` | ~Copyable, Sendable | Write half |
| `IO.Context` | Sendable | Opaque runtime handle (multi-stream) |
| `IO.Error` | Error, Sendable | Flat error enum |
| `IO.Blocking` | Sendable | Thread pool (re-exported from IO Blocking) |
| `IO.Blocking.Handle<T>` | ~Copyable | Deferred result token |
| `IO.Blocking.Error` | Error, Sendable | Blocking infrastructure error |
| `IO.Blocking.Options` | Sendable | Thread pool configuration |

### Tier 1+ — `import IO_Events`

| Type | Conformances | Purpose |
|------|-------------|---------|
| `IO.Event.Channel` | ~Copyable, Sendable | Registered descriptor |
| `IO.Event.Channel.Reader` | ~Copyable, Sendable | Read half (reactor) |
| `IO.Event.Channel.Writer` | ~Copyable, Sendable | Write half (reactor) |
| `IO.Event.Selector` | Sendable | Event multiplexer handle |
| `IO.Event.Selector.Scope` | ~Copyable | Lifecycle owner |
| `IO.Event.Token<Phase>` | ~Copyable, Sendable | Typestate registration token |
| `IO.Event.Driver` | — | Platform driver witness |
| `IO.Event.Error` | Error, Sendable | Reactor error |

### Tier 1+ — `import IO_Completions`

| Type | Conformances | Purpose |
|------|-------------|---------|
| `IO.Completion.Queue` | — | Submission queue |
| `IO.Completion.Driver` | — | Proactor driver witness |
| `IO.Completion.Read` | — | Read operation |
| `IO.Completion.Write` | — | Write operation |
| `IO.Completion.Accept` | — | Accept operation |
| `IO.Completion.Connect` | — | Connect operation |
| `IO.Completion.Error` | Error, Sendable | Proactor error |

---

## IO.Reader and IO.Writer API

The consumer receives these in the `IO.run(descriptor)` closure. They never
construct them.

```swift
extension IO.Reader {
    /// Read next chunk. Returns false on EOF.
    mutating func next() async throws(IO.Error) -> Bool
    
    /// Current chunk (valid after next() returns true).
    var bytes: Span<UInt8> { get }
    
    /// Read all remaining bytes into an array.
    consuming func readAll() async throws(IO.Error) -> [UInt8]
    
    /// Iterate chunks via closure.
    mutating func forEach(
        _ body: (Span<UInt8>) async throws(IO.Error) -> Void
    ) async throws(IO.Error)
    
    /// Pipe all bytes to a writer.
    mutating func pipe(
        to writer: inout IO.Writer
    ) async throws(IO.Error)
    
    /// Shutdown read direction.
    mutating func shutdown() throws(IO.Error)
    
    /// Close read half.
    consuming func close() async throws(IO.Error)
}

extension IO.Writer {
    /// Write bytes. Returns bytes written (may be partial).
    mutating func write(
        _ data: Span<UInt8>
    ) async throws(IO.Error) -> Int
    
    /// Write all bytes (loops internally).
    mutating func write(
        all data: Span<UInt8>
    ) async throws(IO.Error)
    
    /// Shutdown write direction (send FIN).
    mutating func shutdown() throws(IO.Error)
    
    /// Close write half.
    consuming func close() async throws(IO.Error)
}
```

---

## IO.Error — flat, human-readable

```swift
extension IO {
    public enum Error: Swift.Error, Sendable, Equatable {
        case connectionReset
        case brokenPipe
        case notConnected
        case timeout
        case cancelled
        case shutdown
        case platform(Kernel.Error.Code)
    }
}
```

No lifecycle envelope. No per-operation split. No generic parameter.
Tier 1+ consumers who need finer error granularity use
`IO.Event.Error` or `IO.Completion.Error` directly.

---

## Design Principles

### 1. IO.run is the only entry point

No constructors. No factories. No builders. The consumer calls `IO.run`
and gets closures. The runtime manages lifecycle internally.

### 2. Sync vs async via language, not API

`await` selects the async overload. No `await` selects the sync overload.
Same call site, different return type. The compiler is the disambiguator.

### 3. Progressive disclosure via import

`import IO` — app developers. `import IO_Events` — library authors.
The type system enforces the boundary: Tier 1+ types are invisible to
Tier 0 consumers.

### 4. ~Copyable enforces resource lifecycle

Stream, Reader, Writer, Handle are all `~Copyable`. The compiler prevents
double-close, use-after-close, and duplicate consumption. Zero runtime cost.

### 5. No buffer management

The stream owns its internal buffer. The consumer provides `Span<UInt8>`
for writes (borrowed from their own memory) and receives `Span<UInt8>` for
reads (borrowed from the stream's internal buffer). No capacity choice,
no allocation ceremony.

### 6. Blocking is first-class

`IO.run.blocking { }` is Tier 0 — not a separate module, not a second-class
citizen. Every IO framework needs blocking dispatch. It's on `IO.run`.

---

## Prior Art Alignment

| Framework | Entry point | Stream type | Buffer | Our equivalent |
|-----------|------------|-------------|--------|---------------|
| Tokio | `tokio::spawn_blocking` | `TcpStream` | `BytesMut` | `IO.run.blocking`, `IO.run(fd)` |
| Go | `go func(){}` | `net.Conn` | `[]byte` | `IO.run.blocking`, `IO.run(fd)` |
| SwiftNIO | `eventLoop.execute` | `Channel` | `ByteBuffer` | `IO.run.blocking`, `IO.run(fd)` |
| io_uring | `io_uring_submit` | fd | user buffer | `IO.Completion.*` (Tier 1+) |
| epoll | `epoll_ctl` + `epoll_wait` | fd | user buffer | `IO.Event.*` (Tier 1+) |

Key differentiator: every prior art framework requires the consumer to
construct the stream/channel type. `IO.run(fd) { reader, writer in }` is
the only design where the consumer NEVER constructs the transport type.

---

## What's NOT in the API

These are deliberate absences:

| Absent | Why |
|--------|-----|
| `IO.Buffer` constructor | Reader/Writer manage buffers internally |
| `IO.Stream` constructor | `IO.run(fd)` provides stream access via closure |
| `IO.Context` in single-stream use | `IO.run(fd)` creates runtime implicitly |
| `IO.Lifecycle.Error` | Moved to `Async.Lifecycle.Error` in async-primitives |
| `IO.Failure.Work` | Replaced by `Either` from algebra-primitives |
| `IO.Executor.*` | Deleted — premature infrastructure |
| `IO.Handle.Registry` | Deleted — premature infrastructure |
| `IO.Pending/Ready/Scope` | Deleted — premature lifecycle builder DSL |
| `IO.Backend` | Deleted — consumers choose backend by import |
| `for await chunk in stream` | ~Copyable can't conform to AsyncSequence; use `.forEach` |

---

## Implementation Status

| API | Status | File |
|-----|--------|------|
| `IO.run { io in }` | ✅ Implemented | `Sources/IO/IO.Run.swift` |
| `IO.run(fd) { reader, writer in }` | ❌ Not yet | — |
| `IO.run.blocking { }` (async) | ✅ Implemented | `Sources/IO/IO.Run.Blocking.swift` |
| `IO.run.blocking { }` (sync → Handle) | ✅ Implemented | `Sources/IO/IO.Run.Blocking.swift` |
| `IO.read(from:)` | ❌ Not yet | — |
| `IO.write(to:data:)` | ❌ Not yet | — |
| `IO.Reader.forEach` | ❌ Not yet | — |
| `IO.Reader.readAll` | ❌ Not yet | — |
| `IO.Reader.pipe(to:)` | ❌ Not yet | — |
| `IO.Stream` (internal) | ✅ Exists | `Sources/IO/IO.Stream.swift` |
| `IO.Reader` / `IO.Writer` | ✅ Exist | `Sources/IO/IO.Reader.swift`, `IO.Writer.swift` |
| `IO.Context` | ✅ Exists | `Sources/IO/IO.Context.swift` |
| `IO.Error` | ✅ Exists | `Sources/IO/IO.Error.swift` |
| `IO.Blocking` | ✅ Complete | `Sources/IO Blocking/` |

Next: implement `IO.run(fd) { reader, writer in }` — the single-stream
entry point that eliminates Stream/Context construction from consumer code.
