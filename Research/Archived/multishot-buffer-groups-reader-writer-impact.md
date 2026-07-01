---
title: Multishot Recv and Provided Buffer Groups — Impact on Reader/Writer Abstraction
version: 0.1.0
status: IN_PROGRESS
tier: 2
created: 2026-04-16
last_updated: 2026-04-16
applies_to:
  - swift-io
  - swift-kernel-primitives
---

# Context

The io_uring integration session established that completions piggyback
on the Events epoll loop via eventfd — no separate `IO.Completion.Loop`
thread needed. The deeper architectural question was deferred:
io_uring's *advanced* submission modes (multishot recv + provided
buffer groups) break the 1:1 submission→completion assumption that the
current Reader/Writer abstraction implicitly relies on. One multishot
submission can generate N completions as data arrives, and the kernel
picks the buffer from a pool registered ahead of time. This is
materially different from the per-op `(Buffer, Submission, Completion)`
triple the current witness-based design assumes.

# Question

Do multishot recv + provided buffer groups change the Reader/Writer
abstraction design? Specifically:

- If one submission yields N completions, can the witness's `read`
  closure remain `() async throws -> Data`, or does it need an
  async-sequence shape?
- Provided buffer groups require registering a buffer pool with the
  kernel and letting the kernel pick slots. Does the Reader own the
  pool, or does it borrow from a shared proactor-level pool?
- What invariants does the 1:N model impose on cancellation — you can
  cancel the submission, but you cannot un-deliver in-flight
  completions.

# Prior Work

- `swift-foundations/swift-io/Research/io-uring-integration-architecture.md` — monoio, libxev, glommio, tokio-uring prior art
- `swift-foundations/swift-io/Research/io-proactor-buffer-ownership.md` — buffer ownership in proactor model
- `swift-foundations/swift-io/Research/completion-queue-ownership-redesign.md` — no-actor Completions design
- Source reflection: `Research/Reflections/2026-04-09-io-uring-no-separate-loop.md`

# Analysis

_Stub — to be filled in during investigation._

Key sub-questions to work through:

- How does tokio-uring model multishot in its `Stream`/`Sink` types?
- Can the current `@Witness` macro express a "closure returning an
  async sequence" cleanly, or does it require a distinct shape?
- What does the provided-buffer-group lifecycle look like if the pool
  is per-Reader (simpler, worse cache) vs per-proactor (harder, better
  cache)?

# Outcome

_Placeholder — to be filled when analysis completes._

# Provenance

Source: `swift-foundations/swift-io/Research/Reflections/2026-04-09-io-uring-no-separate-loop.md` action item.
