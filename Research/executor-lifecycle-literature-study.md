# Executor and Thread Lifecycle: Literature Study

<!--
---
version: 1.0.0
last_updated: 2026-04-01
status: FINDING
tier: 2
---
-->

## Context

This literature study examines how production I/O frameworks handle the lifecycle of dedicated OS threads (executor threads, poll threads). The goal is to extract concrete patterns for ownership, startup, shutdown, and cleanup enforcement.

Feeds into: [thread-ownership-lifecycle-refactor.md](thread-ownership-lifecycle-refactor.md)

## Frameworks Surveyed

1. Rust Tokio (async runtime, thread pool)
2. SwiftNIO (event loop group, thread management)
3. Node.js / libuv (event loop, thread pool)
4. Linux io_uring / liburing (kernel ring, SQPOLL thread)
5. Go runtime (goroutine scheduler, OS threads)

---

## 1. Rust Tokio

### Who creates the threads?

The `Runtime` object creates threads at construction time. `Runtime::new()` (or `Builder::new_multi_thread().build()`) spawns one worker thread per CPU core by default. The current-thread flavor (`Builder::new_current_thread()`) creates no worker threads -- it runs all tasks on the calling thread when `block_on()` is invoked. Additional threads may be spawned lazily for `spawn_blocking` calls.

Source: [tokio::runtime module docs](https://docs.rs/tokio/latest/tokio/runtime/index.html)

### Who owns them?

**Single owner.** The `Runtime` struct owns all worker threads. Ownership follows Rust's move semantics -- there is exactly one `Runtime` value. Multiple access points are available through `Handle` (does not prevent shutdown) and `Arc<Runtime>` (prevents shutdown while any Arc exists). The `Runtime` is `Send` but not `Clone`.

Source: [Runtime struct docs](https://docs.rs/tokio/latest/tokio/runtime/struct.Runtime.html)

### Who shuts them down?

The `Drop` implementation. When the `Runtime` value is dropped, all spawned tasks are notified to shut down. **The dropping thread blocks until all spawned work has stopped.** This can block indefinitely if tasks do not yield or complete.

Two alternatives exist for controlled shutdown:
- `shutdown_timeout(duration)`: Waits up to `duration`, then **leaks** remaining tasks and threads.
- `shutdown_background()`: Returns immediately, equivalent to `shutdown_timeout(0)`. Intended for dropping a runtime from within another runtime (where blocking would deadlock).

Source: [Runtime struct docs](https://docs.rs/tokio/latest/tokio/runtime/struct.Runtime.html)

### What happens if shutdown is forgotten?

**Cannot happen.** Rust's ownership system guarantees that `Drop` runs when the `Runtime` goes out of scope. There is no way to "forget" shutdown -- it is the destructor. The only risk is that `Drop` blocks indefinitely if tasks are stuck.

The one exception: `std::mem::forget(runtime)` deliberately suppresses the destructor, leaking all threads. This requires explicit opt-in to unsafety.

### How is cleanup enforced?

**Type system (ownership + Drop).** The `Runtime` is a non-`Clone`, non-`Copy` type. When it goes out of scope, `Drop` runs unconditionally. No convention or discipline required.

### Is there a scoped API?

**Yes: `block_on()`.** The canonical pattern is:

```rust
fn main() {
    let rt = Runtime::new().unwrap();
    rt.block_on(async {
        // all async work here
    });
    // rt drops here, all threads join
}
```

`block_on()` itself is not scoped in the RAII sense -- it drives one future to completion. The scoping comes from the `Runtime` value's lifetime. There is no `with_runtime` closure API; the scoped lifetime IS the Rust ownership model.

Tokio does not yet have structured concurrency (scoped tasks). There are open proposals: [tokio-rs/tokio#2592](https://github.com/tokio-rs/tokio/issues/2592), [tokio-rs/tokio#1879](https://github.com/tokio-rs/tokio/issues/1879). Currently, spawned tasks can outlive the scope that spawned them (cancelled on Runtime drop, not on scope exit).

---

## 2. SwiftNIO

### Who creates the threads?

`MultiThreadedEventLoopGroup(numberOfThreads:)` creates the specified number of OS threads at construction. Each thread runs one `SelectableEventLoop`. The thread count is explicit -- there is no default based on CPU count (the caller must choose).

Source: [EventLoopGroup protocol docs](https://swiftinit.org/docs/swift-nio/niocore/eventloopgroup)

### Who owns them?

**Reference-counted (ARC), but shutdown is NOT automatic.** The `MultiThreadedEventLoopGroup` is a class. Multiple references can exist. ARC prevents deallocation while references exist, but ARC does NOT shut down the threads.

NIO's design philosophy: "ARC shouldn't be used to manage scarce resources like file descriptors and threads."

A global singleton (`MultiThreadedEventLoopGroup.singleton`) is available for shared use. The singleton cannot be shut down -- it lives for the process lifetime. Introduced to eliminate the ownership problem for library authors who previously had to decide whether to create or accept an EventLoopGroup.

Source: [apple/swift-nio#571](https://github.com/apple/swift-nio/issues/571)

### Who shuts them down?

**Explicit call: `shutdownGracefully()` or `syncShutdownGracefully()`.** The caller MUST invoke one of these. `shutdownGracefully` takes a callback (not a future, since the event loop it would execute on is being shut down). `syncShutdownGracefully` blocks the calling thread.

Preconditions:
- Must not be called from an EventLoop thread (deadlock)
- Must not be called twice (fatal error)

Source: [apple/swift-nio#1081](https://github.com/apple/swift-nio/issues/1081)

### What happens if shutdown is forgotten?

**Thread leak.** The threads persist indefinitely, consuming system resources. The `deinit` of `MultiThreadedEventLoopGroup` fires a `preconditionFailure` if the group was not shut down first -- this crashes the process in debug builds rather than silently leaking.

For `BlockingIOThreadPool` (the blocking I/O thread pool), the same applies: "worker queues live essentially forever despite the fact that no further work can ever be submitted to them."

Source: [apple/swift-nio#571](https://github.com/apple/swift-nio/issues/571)

### How is cleanup enforced?

**Convention + runtime crash.** There is no compile-time enforcement. The `preconditionFailure` in `deinit` catches violations at runtime (debug builds only). In release builds, the precondition may be elided, leading to silent leaks.

Swift Service Lifecycle provides a container pattern: register shutdown handlers that execute in reverse order when the service shuts down. This moves enforcement from the type system to a framework convention.

Source: [Swift Service Lifecycle blog post](https://www.swift.org/blog/swift-service-lifecycle/)

### Is there a scoped API?

**No built-in scoped API.** There is no `withEventLoopGroup { }` in SwiftNIO. The recommended pattern is:

```swift
let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
defer { try! group.syncShutdownGracefully() }
// ... use group ...
```

Or use the process-lifetime singleton:

```swift
let group = MultiThreadedEventLoopGroup.singleton
// no shutdown needed -- lives forever
```

The Service Lifecycle container provides scoped-like behavior at the application level, but not at the individual resource level.

---

## 3. Node.js / libuv

### Who creates the threads?

**Two thread categories:**

1. **Event loop thread**: The thread that calls `uv_run()` becomes the event loop thread. libuv does not create it -- the caller's thread IS the loop thread. For the default loop (`uv_default_loop()`), this is typically the main thread.

2. **Thread pool**: A global pool of worker threads for blocking operations (file system, DNS, etc.). Default size is 4, configurable via `UV_THREADPOOL_SIZE` environment variable (max 1024). Created lazily on first use, then preallocated to the configured maximum. As of libuv 1.45.0, pool threads have 8 MB stacks. As of 1.50.0, threads are named `libuv-worker`.

Source: [libuv threadpool docs](https://docs.libuv.org/en/v1.x/threadpool.html), [libuv loop source](https://github.com/libuv/libuv/blob/v1.x/src/unix/loop.c)

### Who owns them?

**Event loop**: Owned by whoever allocated the `uv_loop_t` struct. The struct is stack-allocated or heap-allocated by the user, initialized with `uv_loop_init()`, and cleaned up with `uv_loop_close()`. The caller owns the full lifecycle.

**Thread pool**: Process-global, shared across all event loops. No explicit ownership -- it is created once and lives for the process lifetime.

### Who shuts them down?

**Event loop**: The user must:
1. Close all active handles via `uv_close()` (using `uv_walk()` to enumerate them)
2. Run `uv_run()` one more time to process close callbacks
3. Call `uv_loop_close()` to free internal resources

**Thread pool**: No explicit shutdown. Threads are cleaned up on process exit.

Source: [libuv loop source](https://github.com/libuv/libuv/blob/v1.x/src/unix/loop.c)

### What happens if shutdown is forgotten?

**Event loop**: `uv_loop_close()` returns `UV_EBUSY` if handles are still active. The caller must close them first. The internal cleanup asserts: `assert(uv__queue_empty(&loop->wq))` and `assert(!uv__has_active_reqs(loop))`. These assert in debug builds; behavior is undefined in release if violated.

**Thread pool**: No cleanup path exists. Threads persist until process exit.

**Node.js layer**: The event loop exits naturally when no active handles or requests remain. Node checks between each iteration: if no pending I/O, no active timers, and no scheduled callbacks exist, the process exits with code 0. When `main()` finishes, remaining work is discarded.

Source: [Node.js event loop docs](https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick)

### How is cleanup enforced?

**Return codes + assertions.** `uv_loop_close()` returning `UV_EBUSY` is the primary signal. The `uv_walk()` + `uv_close()` pattern is the documented cleanup sequence. No type-system enforcement -- entirely convention-based with runtime error codes.

### Is there a scoped API?

**Yes, implicitly.** The canonical libuv pattern is:

```c
uv_loop_t *loop = malloc(sizeof(uv_loop_t));
uv_loop_init(loop);
// ... register handles ...
uv_run(loop, UV_RUN_DEFAULT);  // blocks until no more work
uv_loop_close(loop);
free(loop);
```

The loop's "scope" is between `uv_loop_init` and `uv_loop_close`. `uv_run(UV_RUN_DEFAULT)` blocks until the loop has no active handles -- this is the natural exit condition. No explicit `with_loop` API, but the blocking `uv_run` serves a similar purpose.

In Node.js, the scoped API is the process itself: the event loop runs until exhaustion, then the process exits.

---

## 4. Linux io_uring / liburing

### Who creates the threads?

**No threads by default.** `io_uring_queue_init()` creates kernel-side ring buffers (submission queue + completion queue) via the `io_uring_setup(2)` syscall and maps them into userspace via `mmap`. No threads are involved in the default mode.

**SQPOLL mode** (`IORING_SETUP_SQPOLL`): The kernel creates a dedicated polling thread (`iou-sqp-<TID>`) that continuously monitors the submission queue. A worker thread (`iou-wrk-<TID>`) is also created. The polling thread goes idle after `sq_thread_idle` milliseconds (default: 1 second) and must be woken via `io_uring_enter()`.

Source: [io_uring_queue_init(3)](https://www.man7.org/linux/man-pages/man3/io_uring_queue_init.3.html), [io_uring_setup(2)](https://man7.org/linux/man-pages/man2/io_uring_setup.2.html), [SQPOLL tutorial](https://unixism.net/loti/tutorial/sq_poll.html)

### Who owns them?

**The io_uring instance (file descriptor).** The kernel allocates resources tied to the file descriptor returned by `io_uring_setup(2)`. The userspace `struct io_uring` holds the mapped memory and fd. Ownership is single -- whoever holds the struct. No reference counting.

**SQPOLL thread**: Owned by the kernel, tied to the io_uring fd. The thread's lifetime is bound to the fd.

### Who shuts them down?

**`io_uring_queue_exit()`**: Unmaps shared memory, closes the io_uring file descriptor. Closing the fd releases all kernel resources.

**SQPOLL thread**: Terminated when the io_uring fd is closed. Known race condition: if pending work exists when shutdown starts, the SQPOLL thread may not have submitted it yet, causing io_uring shutdown to hang.

Source: [io_uring_queue_exit(3)](https://man7.org/linux/man-pages/man3/io_uring_queue_exit.3.html), [SQPOLL shutdown patch](https://lore.gnuweeb.org/io-uring/9b6fab90-e512-f196-1fdb-918f9fee8c16@kernel.dk/t/)

### What happens if shutdown is forgotten?

**Kernel cleanup on fd close / process exit.** Closing the file descriptor (explicitly or via process exit) releases all associated kernel resources. The kernel is the ultimate backstop -- even if `io_uring_queue_exit()` is never called, process termination reclaims everything.

The userspace memory mappings leak until `munmap` or process exit. No userspace assertion or crash -- just leaked mappings.

### How is cleanup enforced?

**fd-based lifecycle (kernel enforced).** The kernel ties all resources to the file descriptor. Closing the fd is the single cleanup action. This is enforced by the kernel's fd lifecycle -- there is no userspace discipline required beyond closing the fd (which the kernel does on process exit regardless).

liburing provides no type-system or API enforcement. The `struct io_uring` is a plain C struct. Convention only.

### Is there a scoped API?

**No.** The pattern is init/exit pairs:

```c
struct io_uring ring;
io_uring_queue_init(256, &ring, 0);
// ... submit and reap ...
io_uring_queue_exit(&ring);
```

The scope is the code between `init` and `exit`. No closure-based or RAII wrapper in liburing. Higher-level frameworks (Tokio's io-uring crate, etc.) wrap this in RAII types with Drop implementations.

---

## 5. Go Runtime

### Who creates the threads?

**The runtime scheduler.** The Go runtime creates OS threads (called "M" in the GMP model) as needed. At startup, one thread exists (m0). Additional threads are created when:
- A goroutine makes a blocking syscall (the P is detached from the blocked M, and a new M is created or unparked to continue running goroutines)
- More parallelism is needed up to the GOMAXPROCS limit

A special `sysmon` thread runs without a P, monitoring the scheduler (preempting long-running goroutines, retaking Ps from blocked Ms). It is created at runtime startup.

Thread count is NOT limited by GOMAXPROCS. GOMAXPROCS limits the number of Ps (logical processors) -- the number of goroutines running *user code* in parallel. The total OS thread count can exceed GOMAXPROCS due to threads blocked in syscalls. Default thread limit is 10,000 (`runtime/debug.SetMaxThreads`).

Source: [runtime package docs](https://pkg.go.dev/runtime), [Go scheduler internals](https://dev.to/debianbaker/inside-the-go-scheduler-how-gmp-model-powers-millions-of-goroutines-940)

### Who owns them?

**The runtime (process-global).** There is no user-facing "runtime" object. The scheduler is initialized automatically at process start. All threads are owned by the runtime. Users cannot create, destroy, or directly manage OS threads.

`LockOSThread()` pins a goroutine to its current thread. If the goroutine exits while locked, the thread is **terminated** (not returned to the pool). This is the only user-facing thread lifecycle control.

### Who shuts them down?

**Process exit.** When `func main()` returns, `os.Exit(0)` is called. All goroutines are terminated immediately -- no cleanup, no deferred functions, no graceful shutdown. The OS reclaims all threads.

Idle threads are **parked** (not destroyed) -- they sleep waiting for work. Parked threads are reused when new work arrives. Thread destruction is rare: only when a locked goroutine exits, or potentially after extended idle periods (implementation-specific, not documented).

Source: [runtime package docs](https://pkg.go.dev/runtime)

### What happens if shutdown is forgotten?

**Not applicable.** There is no explicit shutdown to forget. The runtime starts automatically and ends when the process exits. There is no `runtime.Shutdown()` call. Goroutines that are still running when main returns are killed without cleanup.

This is a deliberate design choice: Go prioritizes simplicity over lifecycle control. The tradeoff is that goroutine cleanup (closing connections, flushing buffers) must be done explicitly before main returns, using patterns like `sync.WaitGroup` or context cancellation.

### How is cleanup enforced?

**Convention only.** There is no type-system enforcement of goroutine lifecycle. The `context.Context` cancellation pattern is the standard convention for signaling shutdown. `sync.WaitGroup` is the standard pattern for waiting on goroutine completion. Both are purely convention -- nothing prevents a goroutine from ignoring cancellation.

Finalizers and cleanups "are not guaranteed to run before program exit."

### Is there a scoped API?

**No.** `go func()` spawns a goroutine with no scope binding. The goroutine runs until it returns or the process exits. There is no `withGoroutine` or structured concurrency primitive.

The closest pattern is manual scoping via WaitGroup:

```go
var wg sync.WaitGroup
wg.Add(1)
go func() {
    defer wg.Done()
    // work
}()
wg.Wait()
```

This is entirely convention-based. The compiler does not enforce that `wg.Done()` is called or that `wg.Wait()` is reached.

---

## Comparison Table

| Dimension | Tokio (Rust) | SwiftNIO | libuv | io_uring | Go Runtime |
|-----------|-------------|----------|-------|----------|------------|
| **Thread creator** | Runtime object | EventLoopGroup object | Caller's thread (loop) + global pool (workers) | Kernel (SQPOLL) or none (default) | Runtime (implicit, on demand) |
| **Ownership model** | Single owner (move semantics) | Reference counted (ARC) | Caller owns loop struct; pool is global | fd-based (single holder) | Process-global (no user object) |
| **Shutdown trigger** | Drop (automatic) | Explicit `shutdownGracefully()` | `uv_loop_close()` after closing all handles | `io_uring_queue_exit()` or fd close | Process exit (implicit) |
| **Forgotten shutdown** | Impossible (Drop runs) | Thread leak + preconditionFailure in deinit | `UV_EBUSY` return + assert in debug | Kernel reclaims on process exit | N/A (no explicit shutdown) |
| **Cleanup enforcement** | **Type system** (ownership + Drop) | Runtime crash (precondition in deinit) | Return code + debug assert | **Kernel** (fd lifecycle) | Convention only (WaitGroup, Context) |
| **Scoped API** | `block_on()` + ownership scope | None (use `defer` or ServiceLifecycle) | `uv_run(DEFAULT)` blocks until exhaustion | None (init/exit pairs) | None (manual WaitGroup) |
| **Blocking on shutdown** | Drop blocks until all tasks complete | `syncShutdownGracefully()` blocks | `uv_run()` blocks; `uv_loop_close()` is sync | `io_uring_queue_exit()` is sync | N/A |
| **Leaked thread risk** | Only via `shutdown_timeout` or `mem::forget` | High (forgotten `shutdownGracefully`) | Pool threads always leak (by design) | SQPOLL thread if fd not closed | Parked threads accumulate (by design) |
| **Process-exit backstop** | OS reclaims | OS reclaims | OS reclaims | **Kernel reclaims** (explicit) | OS reclaims |

---

## Key Findings

### Finding 1: Three Enforcement Strategies Exist

The frameworks fall into three categories of cleanup enforcement:

| Strategy | Framework | Mechanism | Compile-time? |
|----------|-----------|-----------|---------------|
| **Type-system** | Tokio | Rust ownership + Drop | Yes |
| **Kernel-backed** | io_uring | fd lifecycle, kernel reclaims on close | No (but kernel-guaranteed) |
| **Convention** | SwiftNIO, libuv, Go | Explicit calls, runtime checks, patterns | No |

Tokio is the only framework where forgetting cleanup is a **compile error** (the Runtime value must go somewhere -- it is consumed by Drop). io_uring has the strongest runtime backstop (kernel reclaims everything on fd close). SwiftNIO, libuv, and Go rely on discipline.

### Finding 2: Scoped APIs Are Rare

No framework provides a built-in `withRuntime { }` scoped API for thread lifecycle. The closest equivalents:

- **Tokio**: The Runtime value's lexical scope IS the scope (Rust ownership). `block_on()` provides a synchronous entry point.
- **libuv**: `uv_run(UV_RUN_DEFAULT)` blocks until the loop is drained -- the "scope" is the blocking call.
- **SwiftNIO**: No scoped API. ServiceLifecycle provides application-level scoping but not resource-level.
- **io_uring**: No scoped API. Higher-level Rust wrappers add RAII.
- **Go**: No scoped API. `WaitGroup` is the manual alternative.

This validates the approach in [thread-ownership-lifecycle-refactor.md](thread-ownership-lifecycle-refactor.md): scoped APIs for I/O resource lifecycle are a gap in the ecosystem that `~Escapable` scope types can fill.

### Finding 3: The Singleton vs. Scoped Tension Is Universal

Every framework faces the same tension:

| Pattern | Used by | Tradeoff |
|---------|---------|----------|
| **Process-global singleton** | Go (entire runtime), libuv (thread pool), SwiftNIO (`.singleton`) | No lifecycle management needed, but no cleanup either |
| **Owned instance** | Tokio (`Runtime`), SwiftNIO (`MultiThreadedEventLoopGroup`), io_uring (`struct io_uring`) | Clean lifecycle, but user must manage it |

SwiftNIO explicitly introduced `.singleton` to escape the ownership problem for library authors. Go sidesteps it entirely by making the runtime implicit. Tokio forces the user to own the Runtime.

### Finding 4: Drop/Deinit Behavior Diverges

| Framework | Destructor behavior |
|-----------|-------------------|
| Tokio | **Blocks indefinitely** until all tasks complete. `shutdown_timeout` allows bounded waiting. |
| SwiftNIO | **Crashes** (preconditionFailure) if shutdown was not called before deinit. |
| libuv | **Asserts** (debug) if active handles exist. Undefined behavior in release. |
| io_uring | N/A (plain C struct, no destructor). Fd close reclaims kernel resources. |
| Go | N/A (no user-facing runtime object). |

The NIO approach (crash in deinit) is the most defensive but provides no compile-time safety. The Tokio approach (block in Drop) is the most correct but risks deadlock if Drop runs in an async context. The io_uring approach (kernel backstop) is the most robust at the cost of being kernel-specific.

### Finding 5: Async Cleanup in Sync Destructors Is a Universal Problem

Tokio's `Drop` blocks the thread (acceptable because Rust destructors are sync). SwiftNIO forbids calling `syncShutdownGracefully` from an EventLoop (deadlock). io_uring's cleanup is entirely synchronous (kernel syscalls). Go has no async cleanup concept.

This is directly relevant to the `~Escapable` Scope design in [thread-ownership-lifecycle-refactor.md](thread-ownership-lifecycle-refactor.md): Swift's `deinit` is synchronous, so the consuming `close()` async method is the primary path, with deinit as a synchronous emergency fallback. This matches Tokio's approach (sync Drop does the work) but adds an async primary path that Tokio lacks.

### Finding 6: SQPOLL Is the Only Kernel-Managed Thread

io_uring's SQPOLL mode is unique: the kernel creates and manages the polling thread. The thread's lifecycle is tied to the io_uring fd. This is the strongest possible ownership model -- the kernel is the owner, and kernel resource cleanup is guaranteed.

All other frameworks create userspace threads that require userspace cleanup. This is relevant to swift-io's design: for kqueue/epoll-based selectors, we are in the "userspace thread" category and need the stronger enforcement patterns (scoped types or ownership enforcement).

---

## Relevance to swift-io

The literature confirms the design direction in [thread-ownership-lifecycle-refactor.md](thread-ownership-lifecycle-refactor.md):

1. **Tokio's ownership model is the gold standard** for compile-time lifecycle enforcement. Swift's `~Copyable + ~Escapable` can achieve equivalent guarantees with better ergonomics (no closure nesting).

2. **SwiftNIO's preconditionFailure-in-deinit is the current Swift ecosystem norm** -- and it is insufficient (runtime-only, debug-only). The `~Escapable` Scope type is a strict improvement.

3. **The singleton pattern is orthogonal to scoped lifecycle** -- both are needed. Singletons for process-lifetime resources, scoped types for bounded-lifetime resources. Every framework that has both (SwiftNIO with `MultiThreadedEventLoopGroup` + `.singleton`, Tokio with `Runtime` + global executor) confirms this.

4. **Blocking in destructors is acceptable for thread join** -- Tokio does it in Drop, NIO does it in `syncShutdownGracefully`. The sub-millisecond pthread_join blocking documented in the refactor doc is well within established precedent.

5. **No framework has solved async cleanup in sync destructors** -- the consuming `close()` + sync deinit fallback pattern proposed in the refactor doc is novel but follows the same tradeoff every framework makes.

## Sources

### Tokio
- [Runtime struct docs](https://docs.rs/tokio/latest/tokio/runtime/struct.Runtime.html)
- [tokio::runtime module docs](https://docs.rs/tokio/latest/tokio/runtime/index.html)
- [Graceful Shutdown guide](https://tokio.rs/tokio/topics/shutdown)
- [Scoped tasks proposal (tokio-rs/tokio#2592)](https://github.com/tokio-rs/tokio/issues/2592)

### SwiftNIO
- [EventLoopGroup protocol docs](https://swiftinit.org/docs/swift-nio/niocore/eventloopgroup)
- [BlockingIOThreadPool deinit issue (apple/swift-nio#571)](https://github.com/apple/swift-nio/issues/571)
- [Double shutdown hang (apple/swift-nio#1081)](https://github.com/apple/swift-nio/issues/1081)
- [Swift Service Lifecycle blog](https://www.swift.org/blog/swift-service-lifecycle/)

### libuv
- [Event loop API docs](https://docs.libuv.org/en/v1.x/loop.html)
- [Thread pool docs](https://docs.libuv.org/en/v1.x/threadpool.html)
- [Loop cleanup source (libuv/libuv)](https://github.com/libuv/libuv/blob/v1.x/src/unix/loop.c)
- [uv_loop_close EBUSY discussion (libuv/help#156)](https://github.com/libuv/help/issues/156)
- [Node.js event loop docs](https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick)

### io_uring
- [io_uring_queue_init(3) man page](https://www.man7.org/linux/man-pages/man3/io_uring_queue_init.3.html)
- [io_uring_queue_exit(3) man page](https://man7.org/linux/man-pages/man3/io_uring_queue_exit.3.html)
- [io_uring_setup(2) man page](https://man7.org/linux/man-pages/man2/io_uring_setup.2.html)
- [io_uring(7) man page](https://www.man7.org/linux/man-pages/man7/io_uring.7.html)
- [SQPOLL tutorial (Lord of the io_uring)](https://unixism.net/loti/tutorial/sq_poll.html)
- [SQPOLL shutdown race (kernel mailing list)](https://lore.gnuweeb.org/io-uring/9b6fab90-e512-f196-1fdb-918f9fee8c16@kernel.dk/t/)

### Go
- [runtime package docs](https://pkg.go.dev/runtime)
- [GMP scheduler internals](https://dev.to/debianbaker/inside-the-go-scheduler-how-gmp-model-powers-millions-of-goroutines-940)
- [Sysmon monitoring](https://medium.com/@blanchon.vincent/go-sysmon-runtime-monitoring-cff9395060b5)
