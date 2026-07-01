// MARK: - Sync/Async Overload Disambiguation
// Purpose: Determine how Swift resolves sync vs async overloads in async context,
//          and test strategies to make the sync overload reachable.
//
// Toolchain: Swift 6.3
// Platform: macOS 26.0 (arm64)
//
// Result: CONFIRMED — Swift unconditionally picks async overload in async context.
// Revalidated: Swift 6.3.1 (2026-04-30) — PASSES
//         `await` is REQUIRED, not a disambiguator. Three working strategies found.
//
// Key Finding: In async context, when sync and async overloads have the same
// parameter signature, the async overload ALWAYS wins. Calling without `await`
// is a compiler error ("expression is 'async' but is not marked with 'await'").
// @_disfavoredOverload has NO effect on this behavior.
//
// Working Strategies (from async context):
//   1. Return type annotation:   `let _: Handle<Int> = run { 42 }`  → SYNC
//   2. Separate method names:    `enqueue { 42 }` / `run { 42 }`    → unambiguous
//   3. Non-defaulted parameter:  `run { 42 }` (sync) vs
//                                `run(deadline: nil) { 42 }` (async) → unambiguous
//
// Failed Strategies:
//   - @_disfavoredOverload: no effect in async context
//   - Different closure label: trailing closure syntax matches both labels
//   - nonisolated annotation: no effect on overload resolution
//
// Date: 2026-03-26

// ============================================================================
// Infrastructure
// ============================================================================

struct Handle<T: Sendable>: ~Copyable, Sendable {
    let _value: T
    consuming func value() async -> T { _value }
}

enum LaneError: Error, Sendable { case shutdown }

// ============================================================================
// MARK: - V1: Baseline (no @_disfavoredOverload)
// ============================================================================

enum V1 {
    @discardableResult
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) -> Handle<T> {
        print("  → SYNC"); return Handle(_value: op())
    }
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) async -> T {
        print("  → ASYNC"); return op()
    }
}

// ============================================================================
// MARK: - V2: @_disfavoredOverload on async
// ============================================================================

enum V2 {
    @discardableResult
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) -> Handle<T> {
        print("  → SYNC"); return Handle(_value: op())
    }
    @_disfavoredOverload
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) async -> T {
        print("  → ASYNC"); return op()
    }
}

// ============================================================================
// MARK: - V3: @_disfavoredOverload + deadline on async (current IO.run shape)
// ============================================================================

struct Deadline: Sendable {}

enum V3 {
    @discardableResult
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) -> Handle<T> {
        print("  → SYNC"); return Handle(_value: op())
    }
    @_disfavoredOverload
    static func run<T: Sendable>(
        deadline: Deadline? = nil,
        _ op: @Sendable @escaping () -> T
    ) async -> T {
        print("  → ASYNC"); return op()
    }
}

// ============================================================================
// MARK: - V4: Separate names
// ============================================================================

enum V4 {
    @discardableResult
    static func enqueue<T: Sendable>(_ op: @Sendable @escaping () -> T) -> Handle<T> {
        print("  → SYNC (enqueue)"); return Handle(_value: op())
    }
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) async -> T {
        print("  → ASYNC (run)"); return op()
    }
}

// ============================================================================
// MARK: - V5: Return type annotation
// ============================================================================

enum V5 {
    @discardableResult
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) -> Handle<T> {
        print("  → SYNC"); return Handle(_value: op())
    }
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) async -> T {
        print("  → ASYNC"); return op()
    }
}

// ============================================================================
// MARK: - V6: @_disfavoredOverload on SYNC (inverted)
// Hypothesis: Disfavoring sync makes await the natural disambiguator
// ============================================================================

enum V6 {
    @_disfavoredOverload
    @discardableResult
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) -> Handle<T> {
        print("  → SYNC"); return Handle(_value: op())
    }
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) async -> T {
        print("  → ASYNC"); return op()
    }
}

// ============================================================================
// MARK: - V7: Non-defaulted deadline on async
// Hypothesis: Removing the default forces different call-site syntax,
//             making both overloads reachable from async context
// ============================================================================

enum V7 {
    @discardableResult
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) -> Handle<T> {
        print("  → SYNC"); return Handle(_value: op())
    }
    static func run<T: Sendable>(
        deadline: Deadline?,
        _ op: @Sendable @escaping () -> T
    ) async -> T {
        print("  → ASYNC"); return op()
    }
}

// ============================================================================
// MARK: - V8: Async uses `await` label (SE-0296 style naming)
// Hypothesis: A differently-labeled trailing closure disambiguates
// ============================================================================

enum V8 {
    @discardableResult
    static func run<T: Sendable>(_ op: @Sendable @escaping () -> T) -> Handle<T> {
        print("  → SYNC"); return Handle(_value: op())
    }
    static func run<T: Sendable>(
        awaiting op: @Sendable @escaping () -> T
    ) async -> T {
        print("  → ASYNC"); return op()
    }
}

// ============================================================================
// MARK: - Tests
// ============================================================================

func syncContext() {
    print("=== SYNC CONTEXT ===")

    print("\nV1 baseline:")
    let _ = V1.run { 42 }

    print("\nV2 @_disfavoredOverload on async:")
    let _ = V2.run { 42 }

    print("\nV3 @_disfavoredOverload + deadline:")
    let _ = V3.run { 42 }

    print("\nV4 enqueue (separate name):")
    let _ = V4.enqueue { 42 }

    print("\nV5 return type (Handle<Int>):")
    let _: Handle<Int> = V5.run { 42 }

    print("\nV6 @_disfavoredOverload on sync:")
    let _ = V6.run { 42 }
}

@main
struct App {
    static func main() async {
        syncContext()

        print("\n=== ASYNC CONTEXT ===")

        // -- These DON'T compile without await (proven above):
        // V1.run { 42 }   → error: expression is 'async'
        // V2.run { 42 }   → error: expression is 'async' (even with @_disfavoredOverload)
        // V3.run { 42 }   → error: expression is 'async' (even with @_disfavoredOverload)
        // V6.run { 42 }   → error: expression is 'async'

        // -- Strategies that DO compile: --

        print("\nV1 with await (async wins):")
        let _ = await V1.run { 42 }

        print("\nV2 with await (@_disfavoredOverload — which overload?):")
        let _ = await V2.run { 42 }

        print("\nV3 with await (@_disfavoredOverload + deadline):")
        let _ = await V3.run { 42 }

        print("\nV4 enqueue (no await needed — separate name):")
        let _ = V4.enqueue { 42 }

        print("\nV4 run with await:")
        let _ = await V4.run { 42 }

        print("\nV5 return type Handle<Int> (forces sync?):")
        let _: Handle<Int> = V5.run { 42 }

        print("\nV5 with await (forces async?):")
        let _ = await V5.run { 42 }

        print("\nV5 return type Int + await:")
        let _: Int = await V5.run { 42 }

        print("\nV6 @_disfavoredOverload on sync, with await:")
        let _ = await V6.run { 42 }

        print("\nV7 no await, no deadline (sync?):")
        let _ = V7.run { 42 }

        print("\nV7 with deadline + await (async):")
        let _ = await V7.run(deadline: nil) { 42 }

        // V8 fails: trailing closure `V8.run { 42 }` matches `awaiting:` label
        // in async context. Async overload wins. Different label does NOT help
        // with trailing closure syntax.

        print("\nV8 run(awaiting:) explicit label + await (async):")
        let _ = await V8.run(awaiting: { 42 })

        print("\n=== DONE ===")
    }
}
