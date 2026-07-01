# Σ_Stream — Effect Signature (Derived)

> **CORRECTIVE BANNER (2026-04-20)**: This note overshot. It elaborates
> a hypothetical Reader/Writer stream signature (`next`, `flush`,
> `shutdown`, …) that **does not currently exist as a public surface**
> in swift-io. The actual public Σ_IO is the four operations on `IO`:
> `read`, `write`, `close`, `ready` — chunk-level direct access via fd,
> not a streaming abstraction. (See `Sources/IO Core/IO.swift:133` and
> `Research/README.md`.) `IO.Reader` / `IO.Writer` are mentioned in
> `perfect-api.md` as planned API but are not implemented. Treat this
> note as speculative design space, not as describing current code.

<!--
---
version: 1.0.0
created: 2026-04-20
status: DRAFT
purpose: |
  Per-component signature note for the Stream (byte-stream)
  sub-theory of Σ_IO. Σ_Stream is *derived*: handlers factor through
  Σ_Event or Σ_Completion. This note states the signature, the laws,
  and the factorisation contract.

basis: io-algebraic-effects-foundation.md §6.4, swift-io-thesis.md §3.4
---
-->

## 1. Position

Σ_Stream captures the **byte-stream** abstraction the consumer sees
in `IO.run(descriptor) { reader, writer in ... }`. It does not
add new kernel-level capability; it provides the algebraic
interface to chunk-by-chunk reading and writing, with EOF detection,
flushing, half-close, and full-close.

Σ_Stream is **derived**: every handler `H_Stream` is implemented as
a *transformation* into Σ_Event or Σ_Completion. This factorisation
is what makes Σ_Stream worth having as a distinct signature — it
hides the readiness/completion choice from the consumer while
preserving operational laws.

## 2. Operations

```
next      : Reader  → Option<Span<UInt8>>
write     : (Writer, Span<UInt8>) → Count
write_all : (Writer, Span<UInt8>) → 1
flush     : Writer → 1
shutdown  : Half → 1
close     : Half → 1
```

Where `Half ∈ {Reader, Writer}`.

`next` returns `None` to signal EOF; `Some(span)` to deliver a chunk.
The span borrows from the reader's internal buffer; it is valid
until the next call to `next`.

`write_all` is a derived operation:
```
write_all(w, data)
  ≡
  if data.isEmpty then return ()
  else write(w, data) >>= λn.
       write_all(w, data.dropFirst(n))
```
It is included in the signature because it is the predominant
consumer pattern and benefits from handler-level fusion (single
syscall vs. loop in user code).

## 3. Types

| Symbol | Concrete Swift |
|--------|----------------|
| `Reader` | `IO.Reader` (~Copyable, ~Sendable, single-consumer) |
| `Writer` | `IO.Writer` (~Copyable, ~Sendable, single-producer) |
| `Half` | union; concretely the consuming methods on Reader / Writer |
| `Span<UInt8>` | borrow of a contiguous byte region |
| `Count` | `Int` (bytes actually transferred) |

Linearity: `Reader` and `Writer` are `~Copyable`. They are
single-use channels; the type system prevents double-close,
use-after-close, and concurrent consumption.

## 4. Equational laws (E_Stream)

### 4.1 EOF terminality
```
once next(r) returns None,
  next(r) returns None forever
```
A reader that has signalled EOF stays at EOF. The handler may not
"un-EOF" a reader. This is observable: any subsequent call to
`next` must return `None`.

### 4.2 Zero-write triviality
```
write(w, ∅)   ≡   return 0
```
Writing an empty span is observationally equal to returning zero.
Handler may skip the syscall entirely.

### 4.3 Close idempotence
```
close(h); close(h)   ≡   close(h)
```
Closing an already-closed half is a no-op. (Compile-time enforced by
~Copyable: the second close is a use-after-consume error. Kept here
as a semantic law for any code path that materialises the half via
escape hatches.)

### 4.4 Shutdown-then-close fuse
```
shutdown(h); close(h)   ≡   close(h)
```
Shutdown followed immediately by close is observationally equal to
just close. The handler may fuse the syscalls.

### 4.5 Flush observability
```
write(w, data); close(w)   ⊨   data is delivered
```
A close on a writer must deliver any pending writes (FIN sent after
data, not before). Handler must flush before signalling close
completion.

### 4.6 Pipe equivalence
```
pipe(r, w)
  ≡
  forever {
    next(r) >>= {
      | None      → close(w)
      | Some(s)   → write_all(w, s)
    }
  }
```
The high-level `pipe` operation (foundation §6.4 mentions but the
op set above does not include) is a derived combinator; this
equation establishes its semantics. If a handler chooses to
implement `pipe` directly (e.g. as `splice(2)` on Linux), it must
preserve this equation.

## 5. Factorisation: Σ_Stream ⇒ Σ_Event | Σ_Completion

A `H_Stream` handler must factor through one of the lower
signatures. Two recipes:

### 5.1 Via Σ_Event (reactor)

```
next(r):
  loop {
    poll the descriptor's read buffer non-blocking
    if data:    return Some(span over buffer up to len)
    if EOF:     return None
    if EAGAIN:  wait(r.token)         -- Σ_Event op
  }

write(w, span):
  poll non-blocking write
  if EAGAIN:
    wait(w.token)                     -- Σ_Event op
    poll again
  return n
```

### 5.2 Via Σ_Completion (proactor)

```
next(r):
  let n = submit_read(r.fd, r.buffer, r.offset)   -- Σ_Completion
  if n == 0:  return None
  return Some(span over r.buffer[0..<n])

write(w, span):
  let n = submit_write(w.fd, span, w.offset)      -- Σ_Completion
  return n
```

Both factorisations satisfy E_Stream. The choice is platform / policy
driven and invisible to consumers.

## 6. Handler obligations

A handler `H_Stream` must:

1. Provide concrete `Reader` / `Writer` values bound to a
   descriptor and an internal buffer.
2. Discharge each operation by reducing to lower-signature
   operations per §5.
3. Preserve E_Stream §4.1 — §4.5 across the factorisation. (§4.6
   only if `pipe` is exposed.)
4. Manage the internal buffer's lifecycle: allocate on Reader /
   Writer construction; release on `close`.
5. Honour `~Copyable` linearity: each Reader / Writer is consumed
   at most once.

Cancellation: `next` and `write` on a cancelled task throw
`CancellationError`. The Reader / Writer remains usable (the next
call is a fresh attempt). `close` on a cancelled task still
performs the close.

## 7. Current implementation

| Element | Source |
|---------|--------|
| Reader | `IO.Reader` (Sources/IO/IO.Reader.swift) |
| Writer | `IO.Writer` (Sources/IO/IO.Writer.swift) |
| Stream (internal) | `IO.Stream` (Sources/IO/IO.Stream.swift) |
| Consumer entry | `IO.run(descriptor) { reader, writer in ... }` |
| Convenience | `IO.read(from:)`, `IO.write(to:data:)` |
| Pipe | `IO.Reader.pipe(to: &IO.Writer)` (planned) |
| Error type | `IO.Error` (flat enum) |
| Factorisation | Reactor today; Proactor when `IO.Completion.Driver` available |

See `perfect-api.md` §"IO.Reader and IO.Writer API" for the full
surface; `channel-full-duplex-split.md` for the linear half-split
rationale.

## 8. Open work

1. **`forEach` and `readAll` as algebraic operations**: today they
   are derived combinators in user code; consider promoting if
   handler-level fusion (e.g. read-into-async-iterator) becomes
   valuable.
2. **`pipe` as a primitive**: Linux's `splice(2)` and `sendfile(2)`
   permit zero-copy descriptor-to-descriptor transfer. If exposed
   as `Σ_Stream.pipe : (Reader, Writer) → Count`, a Linux handler
   may discharge by `splice`; other platforms factor via
   read/write loop.
3. **Backpressure semantics**: Σ_Stream currently has no notion of
   the reader signalling "stop" to the writer of the upstream
   producer. This is a higher-level concern (Σ_Channel /
   Σ_AsyncSequence) and intentionally out of scope.
4. **`AsyncSequence` conformance impossibility**: Reader is
   `~Copyable`, which blocks `AsyncSequence` conformance. The
   `forEach` workaround is the consumer-facing answer. Re-evaluate
   if/when Swift permits `~Copyable AsyncSequence`.
