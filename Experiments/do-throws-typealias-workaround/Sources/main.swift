// MARK: - do throws(ComplexGenericType) Typealias Workaround
// Purpose: Validate whether a private typealias avoids the Swift compiler crash
//          when using `do throws(IO.Lifecycle.Error<Either<IO.Blocking.Lane.Error, Never>>)`
// Hypothesis: The compiler crashes on the inline complex generic type but a typealias
//             simplifies resolution enough to avoid the crash
//
// Toolchain: swift-6.2
// Status: SUPERSEDED 2026-04-30 — Transitive dependency swift-posix unable to find type 'Kernel' in scope; experiment cannot build until dependency chain is fixed
// Revalidated: Swift 6.3.1 (2026-04-30) — STILL PRESENT (package drift; SUPERSEDED per [META-007])
// Platform: macOS 26.0 (arm64)
//
// Result: REFUTED — all variants compile, including inline. The original
//         compiler crash in io-bench was a stale incremental build artifact.
//         After `swift package clean`, inline do throws(IO.Lifecycle.Error<
//         Either<IO.Blocking.Lane.Error, Never>>) compiles in io-bench too.
//         No typealias workaround needed.
// Date: 2026-03-25

import IO

// MARK: - Variant 1: Inline complex generic type (expected: CRASH)
// Hypothesis: do throws(IO.Lifecycle.Error<Either<IO.Blocking.Lane.Error, Never>>) crashes
// Result: PENDING

func variant1_inline() async {
    let lane = IO.Blocking.Lane.threads(.init())
    defer { Task { await lane.shutdown() } }

    Task {
        do throws(IO.Lifecycle.Error<Either<IO.Blocking.Lane.Error, Never>>) {
            try await lane.run(deadline: Clock.Suspending.Instant?.none) { () -> Void in }
        } catch {
            switch error {
            case .cancellation, .shutdownInProgress:
                return
            case .timeout, .failure:
                fatalError("unexpected: \(error)")
            }
        }
    }
}

// MARK: - Variant 2: File-scope typealias (expected: COMPILES)
// Hypothesis: Typealias simplifies the type enough for the compiler
// Result: PENDING

private typealias _LaneRunError = IO.Lifecycle.Error<Either<IO.Blocking.Lane.Error, Never>>

func variant2_typealias() async {
    let lane = IO.Blocking.Lane.threads(.init())
    defer { Task { await lane.shutdown() } }

    Task {
        do throws(_LaneRunError) {
            try await lane.run(deadline: Clock.Suspending.Instant?.none) { () -> Void in }
        } catch {
            switch error {
            case .cancellation, .shutdownInProgress:
                return
            case .timeout, .failure:
                fatalError("unexpected: \(error)")
            }
        }
    }
}

// MARK: - Variant 3: Enum-scoped typealias (expected: COMPILES)
// Hypothesis: Same as V2 but scoped to a type, matching fixture pattern
// Result: PENDING

enum FakeFixture {
    private typealias _RunError = IO.Lifecycle.Error<Either<IO.Blocking.Lane.Error, Never>>

    static func variant3_scoped() async {
        let lane = IO.Blocking.Lane.threads(.init())
        defer { Task { await lane.shutdown() } }

        Task {
            do throws(_RunError) {
                try await lane.run(deadline: Clock.Suspending.Instant?.none) { () -> Void in }
            } catch {
                switch error {
                case .cancellation, .shutdownInProgress:
                    return
                case .timeout, .failure:
                    fatalError("unexpected: \(error)")
                }
            }
        }
    }
}

// MARK: - Variant 4: Exact fixture pattern (captured mutex + condition.wait)
// Hypothesis: The crash requires the specific closure body from the fixtures
// Result: PENDING

import Kernel

func variant4_fixture_pattern() async {
    let lane = IO.Blocking.Lane.threads(.init())
    let mutex = Kernel.Thread.Mutex()
    let condition = Kernel.Thread.Condition()

    Task {
        do throws(IO.Lifecycle.Error<Either<IO.Blocking.Lane.Error, Never>>) {
            try await lane.run(deadline: Clock.Suspending.Instant?.none) {
                mutex.lock()
                condition.wait(mutex: mutex)
                mutex.unlock()
            }
        } catch {
            switch error {
            case .cancellation, .shutdownInProgress:
                return
            case .timeout, .failure:
                fatalError("unexpected: \(error)")
            }
        }
    }

    condition.broadcast()
    await lane.shutdown()
}

// MARK: - Results Summary
// V1 (inline, IO types):       PENDING
// V2 (typealias, file-scope):  PENDING
// V3 (typealias, enum-scoped): PENDING

print("All variants compiled successfully")
