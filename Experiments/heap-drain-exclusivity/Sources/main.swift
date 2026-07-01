// MARK: - Heap drain(while:_:) Exclusivity Experiment
// Purpose: Test whether Swift 6.2 features can resolve the exclusivity
//          conflict when drain(while:_:)'s body needs sibling state access.
//
// Context: In swift-io, Acceptance.Queue.Expired.cancel() cannot use
//          queue.deadlineHeap.drain(while:_:) because the body closure
//          accesses queue.cancel(), and Swift's exclusivity checker sees
//          overlapping access to `queue` (the shared aggregate).
//
// Hypothesis: One of these approaches enables "best of all worlds":
//   V1: Baseline — closure-based drain (expected: exclusivity error)
//   V2: ~Escapable iterator with @_lifetime — for loop releases borrow between iterations
//   V3: Temporary field split — move heap out, drain, move back
//   V4: Collect-then-process — drain into array, then iterate
//   V5: withUnsafeMutablePointer — unsafe escape hatch
//
// Toolchain: Swift 6.2 (Xcode 26 beta)
// Platform: macOS 26.0 (arm64)
//
// Result: No Swift 6.2 feature resolves the fundamental exclusivity conflict.
//          V6 (manual peek/take loop) remains the best safe pattern.
//          V3 (temporary field split) is the best alternative if drain() is desired.
//          ~Escapable + @_lifetime (V2) does NOT help — the pointer still aliases the aggregate.
// Date: 2026-02-24

// ============================================================================
// Minimal reproduction of the swift-io pattern
// ============================================================================

/// Simulates Heap<Entry> with drain(while:_:)
struct MiniHeap {
    private var storage: [Entry] = []

    struct Entry: Comparable {
        let deadline: UInt64
        let ticket: Int
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.deadline < rhs.deadline }
    }

    mutating func push(_ entry: Entry) {
        storage.append(entry)
        storage.sort()
    }

    var peek: Entry? { storage.first }

    mutating func take() -> Entry? {
        storage.isEmpty ? nil : storage.removeFirst()
    }

    /// Closure-based drain — holds mutable borrow across body invocation
    mutating func drain(
        while predicate: (borrowing Entry) -> Bool,
        _ body: (consuming Entry) -> Void
    ) {
        while let element = peek, predicate(element) {
            body(take()!)
        }
    }
}

/// Simulates the Acceptance.Queue aggregate
struct Queue {
    var heap: MiniHeap = .init()
    var cancelledCount: Int = 0

    mutating func cancel(ticket: Int) -> Bool {
        cancelledCount += 1
        return true
    }
}

// ============================================================================
// MARK: - V1: Baseline (closure-based drain)
// Hypothesis: Exclusivity error — drain holds mutable borrow on queue.heap,
//             body accesses queue.cancel()
// Result: CONFIRMED — exclusivity error (uncomment to verify)
// ============================================================================

// UNCOMMENT TO VERIFY EXCLUSIVITY ERROR:
// func v1_closureDrain() {
//     var queue = Queue()
//     queue.heap.push(.init(deadline: 0, ticket: 1))
//     queue.heap.drain(while: { $0.deadline == 0 }) { entry in
//         _ = queue.cancel(ticket: entry.ticket)  // ERROR: overlapping access
//     }
// }

// ============================================================================
// MARK: - V2: ~Escapable iterator with @_lifetime
// Hypothesis: A ~Escapable iterator returned from mutating method allows
//             interleaving heap mutation and sibling state access via for loop.
// Result: REFUTED — compiles and drains correctly, but cannot access sibling
//         state (queue.cancel()) in the loop body because the pointer to
//         queue.heap still constitutes a borrow on queue.
// ============================================================================

extension MiniHeap {
    @unsafe
    struct DrainIterator: ~Copyable, ~Escapable {
        var heap: UnsafeMutablePointer<MiniHeap>
        let predicate: (borrowing Entry) -> Bool

        @_lifetime(borrow heap)
        init(heap: UnsafeMutablePointer<MiniHeap>, predicate: @escaping (borrowing Entry) -> Bool) {
            self.heap = heap
            self.predicate = predicate
        }

        mutating func next() -> Entry? {
            guard let element = unsafe heap.pointee.peek, predicate(element) else {
                return nil
            }
            return unsafe heap.pointee.take()
        }
    }
}

func v2_escapableIterator() {
    var queue = Queue()
    queue.heap.push(.init(deadline: 0, ticket: 1))
    queue.heap.push(.init(deadline: 0, ticket: 2))
    queue.heap.push(.init(deadline: 999, ticket: 3))

    unsafe withUnsafeMutablePointer(to: &queue.heap) { heapPtr in
        var iter = unsafe MiniHeap.DrainIterator(
            heap: heapPtr,
            predicate: { $0.deadline == 0 }
        )
        while let entry = iter.next() {
            // Can we access sibling state here?
            // queue.cancel() would be exclusivity violation since we hold heapPtr
            // which was derived from &queue.heap (part of queue).
            // So we just record — proving the iterator pattern works in isolation.
            print("  V2: drained ticket \(entry.ticket)")
        }
    }

    print("V2 (~Escapable iterator): remaining heap peek = \(queue.heap.peek?.ticket ?? -1)")
    print("  NOTE: Cannot call queue.cancel() in body — pointer to queue.heap")
    print("        still constitutes a borrow on queue. ~Escapable does NOT solve")
    print("        the fundamental exclusivity issue.\n")
}

// ============================================================================
// MARK: - V3: Temporary field split — move heap out, drain, move back
// Hypothesis: Moving the heap to a local variable breaks the aggregate
//             aliasing. drain() on the local has no overlap with self.
// Result: CONFIRMED — compiles, runs, and allows sibling state access.
//         Output: cancelled 2, remaining: 3
// ============================================================================

extension Queue {
    mutating func drainExpiredV3() -> Int {
        var count = 0
        var tempHeap = self.heap
        self.heap = MiniHeap()

        tempHeap.drain(while: { $0.deadline == 0 }) { entry in
            if self.cancel(ticket: entry.ticket) {
                count += 1
            }
        }

        self.heap = tempHeap
        return count
    }
}

func v3_temporarySplit() {
    var queue = Queue()
    queue.heap.push(.init(deadline: 0, ticket: 1))
    queue.heap.push(.init(deadline: 0, ticket: 2))
    queue.heap.push(.init(deadline: 999, ticket: 3))

    let count = queue.drainExpiredV3()
    print("V3 (temporary split): cancelled \(count), remaining: \(queue.heap.peek?.ticket ?? -1)\n")
}

// ============================================================================
// MARK: - V4: Collect-then-process
// Hypothesis: Collect drained entries, then process. Allocates, but clean.
// Result: CONFIRMED — compiles, runs, allows sibling state access.
//         Output: cancelled 2, remaining: 3. Allocates temp array.
// ============================================================================

func v4_collectThenProcess() {
    var queue = Queue()
    queue.heap.push(.init(deadline: 0, ticket: 1))
    queue.heap.push(.init(deadline: 0, ticket: 2))
    queue.heap.push(.init(deadline: 999, ticket: 3))

    var expired: [MiniHeap.Entry] = []
    queue.heap.drain(while: { $0.deadline == 0 }) { expired.append($0) }

    var count = 0
    for entry in expired {
        if queue.cancel(ticket: entry.ticket) {
            count += 1
        }
    }

    print("V4 (collect-then-process): cancelled \(count), remaining: \(queue.heap.peek?.ticket ?? -1)\n")
}

// ============================================================================
// MARK: - V5: withUnsafeMutablePointer — unsafe escape hatch
// Hypothesis: Taking a pointer to self before drain bypasses exclusivity.
//             Compiles and runs but is unsafe.
// Result: CONFIRMED — compiles, runs, allows sibling state access.
// Revalidated: Swift 6.3.1 (2026-04-30) — PASSES
//         Output: cancelled 2, remaining: 3. Unsafe.
// ============================================================================

extension Queue {
    mutating func drainExpiredV5() -> Int {
        var count = 0
        unsafe withUnsafeMutablePointer(to: &self) { queuePtr in
            unsafe queuePtr.pointee.heap.drain(while: { $0.deadline == 0 }) { entry in
                if unsafe queuePtr.pointee.cancel(ticket: entry.ticket) {
                    count += 1
                }
            }
        }
        return count
    }
}

func v5_unsafePointer() {
    var queue = Queue()
    queue.heap.push(.init(deadline: 0, ticket: 1))
    queue.heap.push(.init(deadline: 0, ticket: 2))
    queue.heap.push(.init(deadline: 999, ticket: 3))

    let count = queue.drainExpiredV5()
    print("V5 (withUnsafeMutablePointer): cancelled \(count), remaining: \(queue.heap.peek?.ticket ?? -1)\n")
}

// ============================================================================
// MARK: - V6: Manual loop (current production pattern, for comparison)
// This is what swift-io actually uses. Included as the reference.
// ============================================================================

func v6_manualLoop() {
    var queue = Queue()
    queue.heap.push(.init(deadline: 0, ticket: 1))
    queue.heap.push(.init(deadline: 0, ticket: 2))
    queue.heap.push(.init(deadline: 999, ticket: 3))

    var count = 0
    while let top = queue.heap.peek, top.deadline == 0 {
        _ = queue.heap.take()
        if queue.cancel(ticket: top.ticket) {
            count += 1
        }
    }

    print("V6 (manual loop — production): cancelled \(count), remaining: \(queue.heap.peek?.ticket ?? -1)\n")
}

// ============================================================================
// MARK: - Run All Variants
// ============================================================================

print("=== Heap drain(while:_:) Exclusivity Experiment ===\n")
v2_escapableIterator()
v3_temporarySplit()
v4_collectThenProcess()
v5_unsafePointer()
v6_manualLoop()

print("=== Summary ===")
print("V1 (closure drain):          EXCLUSIVITY ERROR — cannot compile")
print("V2 (~Escapable iterator):    Compiles but does NOT solve the problem")
print("                             (pointer to heap still aliases queue)")
print("V3 (temporary split):        COMPILES & RUNS — safe, zero-allocation")
print("                             if heap uses CoW (just a retain+release)")
print("V4 (collect-then-process):   COMPILES & RUNS — allocates temp array")
print("V5 (withUnsafeMutablePointer): COMPILES & RUNS — unsafe escape hatch")
print("V6 (manual loop):            COMPILES & RUNS — current production pattern")
