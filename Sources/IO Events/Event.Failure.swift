//
//  Event.Failure.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 29/12/2025.
//

// Windows: the event reactor is built on Kernel.Event.Source (epoll/kqueue)
// and Kernel.Thread.Executor.Polling — POSIX-only surfaces (swift-executors
// gates Polling !os(Windows)). Gated whole-file to match the IO Completions
// posture; the Windows leg uses the blocking path per IO+File.System+Default.
#if !os(Windows)
public import Either_Primitives
public import Async

extension Event {
    /// Canonical failure type for non-blocking I/O operations.
    ///
    /// `Either<Async.Lifecycle.Error, Event.Error>` — the lifecycle envelope
    /// (shutdown / cancellation / timeout) on the left, the leaf I/O error
    /// (``Event/Error``) on the right. This matches the composition pattern
    /// codified at `Async.Lifecycle.Error` ("composition with body / domain
    /// errors moves into `Either<Async.Lifecycle.Error, E>` at the API
    /// surface"), avoiding the historical generic `Async.Lifecycle.Error<E>`
    /// shape (refactored to non-generic in swift-async-primitives).
    ///
    /// ## Usage
    ///
    /// ```swift
    /// func operation() async throws(Failure) -> T
    /// CheckedContinuation<T, Failure>
    ///
    /// // Construction at throw sites:
    /// throw .left(.cancelled)        // lifecycle: cancelled
    /// throw .left(.shutdown)         // lifecycle: shutdown-in-progress
    /// throw .left(.timeout)          // lifecycle: timeout
    /// throw .right(.invalidDescriptor)  // leaf I/O failure
    /// ```
    public typealias Failure = Either<Async.Lifecycle.Error, Event.Error>
}

#endif
