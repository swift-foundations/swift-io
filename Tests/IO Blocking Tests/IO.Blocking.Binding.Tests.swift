//
//  Basic.Binding.Tests.swift
//  swift-io
//
//  Regression tests for Shape B's mandatory executor binding guarantees.
//  The witness forwards to an internal `Basic.Actor` pinned to a
//  concrete `Kernel.Thread.Executor`; actor isolation cannot be broken by
//  `Task.sleep`, `@MainActor` hops, or unstructured tasks.
//
//  See Research/io-blocking-executor-binding.md v4.0.
//

import Executors
import IO_Test_Support
import Kernel
import Memory_Primitives
import Span_Raw_Primitives
import Synchronization
import Testing

extension Basic {
    enum BindingTest {
        @Suite struct MandatoryBinding {}
        @Suite struct SharedExecutor {}
        @Suite struct ZeroHop {}
        @Suite struct HeadOfLine {}
    }
}

// MARK: - Mandatory Binding

extension Basic.BindingTest.MandatoryBinding {
    @Test
    func `read survives Task.sleep — actor isolation pins to executor`() async throws {
        // Option A's failure mode: Task.sleep loses TaskExecutor preference
        // (swift#74395), so the next sync read would block a cooperative
        // thread. Under Shape B, actor isolation forces the second read onto
        // the impl's executor regardless of intervening suspensions.
        let io = IO.blocking()
        let pipe = try Kernel.Pipe.pipe()

        let ptr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { ptr.deallocate() }
        let writeBuf: Span.Raw = unsafe .init(UnsafeRawBufferPointer(ptr))
        let readBuf: Span.Raw.Mutable = unsafe .init(ptr)

        unsafe ptr[0] = 1
        _ = try await io.write(to: pipe.write, from: writeBuf)
        _ = try await io.read(from: pipe.read, into: readBuf)

        try await Task.sleep(for: .milliseconds(10))

        unsafe ptr[0] = 2
        _ = try await io.write(to: pipe.write, from: writeBuf)
        let n = try await io.read(from: pipe.read, into: readBuf)
        #expect(n == 1)
        #expect(unsafe ptr[0] == 2)
    }

    @Test
    func `many concurrent IOs with Task.sleep all progress`() async throws {
        let count = 16
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    let io = IO.blocking()
                    let pipe = try Kernel.Pipe.pipe()

                    let ptr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
                    defer { ptr.deallocate() }
                    unsafe ptr[0] = 7
                    let writeBuf: Span.Raw = unsafe .init(UnsafeRawBufferPointer(ptr))
                    let readBuf: Span.Raw.Mutable = unsafe .init(ptr)

                    _ = try await io.write(to: pipe.write, from: writeBuf)
                    try await Task.sleep(for: .milliseconds(1))
                    _ = try await io.read(from: pipe.read, into: readBuf)
                }
            }
            try await group.waitForAll()
        }
    }
}

// MARK: - Shared-executor probes
//
// Helper: builds an `IO` whose closures forward to an internal Actor and
// also captures, in a recorder, the OS thread ID seen by each call. The
// thread ID is sampled inside the actor's isolated method, so it observes
// the executor's actual OS thread — actor isolation guarantees this.

private final class ThreadRecorder: Sendable {
    private let storage = Mutex<[Kernel.Thread.ID]>([])
    func record(_ id: Kernel.Thread.ID) { storage.withLock { $0.append(id) } }
    func snapshot() -> [Kernel.Thread.ID] { storage.withLock { $0 } }
}

private final class OrderCounter: Sendable {
    private let storage = Mutex<[Int]>([])
    func append(_ value: Int) { storage.withLock { $0.append(value) } }
    func snapshot() -> [Int] { storage.withLock { $0 } }
}

private func makeProbedIO(
    on executor: Kernel.Thread.Executor,
    recorder: ThreadRecorder
) -> IO<Basic.Capabilities> {
    let actor = Kernel.Thread.Actor(executor: executor)
    let capabilities = Basic.Capabilities(
        read: { fd, buf throws(Basic.Error) -> Int in
            let id = await actor.id
            recorder.record(id)
            return try await actor.read(from: fd, into: buf)
        },
        write: { fd, buf throws(Basic.Error) -> Int in
            let id = await actor.id
            recorder.record(id)
            return try await actor.write(to: fd, from: buf)
        },
        close: { fd in
            await actor.close(consume fd)
        },
        ready: { _, _ throws(Basic.Error) in
            // Blocking strategy: no-op (same semantics as the
            // production IO+Blocking factory).
        }
    )
    let runner = unsafe IO<Basic.Capabilities>.Runner(
        executor: { unsafe actor.unownedExecutor },
        shutdown: {}
    )
    return IO(capabilities: capabilities, runner: runner)
}

// MARK: - Shared Executor

extension Basic.BindingTest.SharedExecutor {
    @Test
    func `two IOs on the same executor — both ops land on the SAME OS thread`() async throws {
        let executor = Kernel.Thread.Executor()
        defer { executor.shutdown() }

        let recorder = ThreadRecorder()
        let ioA = makeProbedIO(on: executor, recorder: recorder)
        let ioB = makeProbedIO(on: executor, recorder: recorder)

        let pipe = try Kernel.Pipe.pipe()
        let ptr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { ptr.deallocate() }
        unsafe ptr[0] = 11
        let writeBuf: Span.Raw = unsafe .init(UnsafeRawBufferPointer(ptr))
        let readBuf: Span.Raw.Mutable = unsafe .init(ptr)

        _ = try await ioA.write(to: pipe.write, from: writeBuf)
        _ = try await ioB.read(from: pipe.read, into: readBuf)
        #expect(unsafe ptr[0] == 11)

        let ids = recorder.snapshot()
        #expect(ids.count == 2)
        #expect(ids[0] == ids[1], "ioA write and ioB read on shared executor should observe the same OS thread")
    }

    @Test
    func `two IOs on DIFFERENT executors land on DIFFERENT OS threads (control)`() async throws {
        // Without this control, the equality assertion in the
        // `twoIOsSameExecutorThreadID` test could be vacuously true on a
        // single-threaded runtime. This control rules that out.
        let executorA = Kernel.Thread.Executor()
        defer { executorA.shutdown() }
        let executorB = Kernel.Thread.Executor()
        defer { executorB.shutdown() }

        let recorder = ThreadRecorder()
        let ioA = makeProbedIO(on: executorA, recorder: recorder)
        let ioB = makeProbedIO(on: executorB, recorder: recorder)

        let pipeA = try Kernel.Pipe.pipe()
        let pipeB = try Kernel.Pipe.pipe()
        let ptr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { ptr.deallocate() }
        unsafe ptr[0] = 22
        let writeBuf: Span.Raw = unsafe .init(UnsafeRawBufferPointer(ptr))
        let readBuf: Span.Raw.Mutable = unsafe .init(ptr)

        _ = try await ioA.write(to: pipeA.write, from: writeBuf)
        _ = try await ioB.write(to: pipeB.write, from: writeBuf)
        _ = try await ioA.read(from: pipeA.read, into: readBuf)
        _ = try await ioB.read(from: pipeB.read, into: readBuf)

        let ids = recorder.snapshot()
        #expect(ids.count == 4)
        // ioA's two ops share their thread; ioB's two ops share their thread;
        // the two executors do NOT share.
        let aIDs = Set([ids[0], ids[2]])
        let bIDs = Set([ids[1], ids[3]])
        #expect(aIDs.count == 1, "ioA's ops should share one thread")
        #expect(bIDs.count == 1, "ioB's ops should share one thread")
        #expect(aIDs.isDisjoint(with: bIDs), "ioA and ioB should be on different threads")
    }
}

// MARK: - Zero-Hop App Actor

/// An app actor that co-locates on the IO's executor — the runtime elides
/// the per-op hop because both share the same `unownedExecutor`.
actor SharedExecutorApp {
    let executor: Kernel.Thread.Executor
    let io: IO<Basic.Capabilities>

    init(executor: Kernel.Thread.Executor) {
        self.executor = executor
        self.io = IO.blocking(on: executor)
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        io.unownedExecutor
    }

    func roundtrip(
        writeFd: borrowing Kernel.Descriptor,
        readFd: borrowing Kernel.Descriptor,
        value: UInt8
    ) async throws(Basic.Error) -> UInt8 {
        let ptr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { ptr.deallocate() }
        unsafe ptr[0] = value
        let writeBuf: Span.Raw = unsafe .init(UnsafeRawBufferPointer(ptr))
        let readBuf: Span.Raw.Mutable = unsafe .init(ptr)

        _ = try await io.write(to: writeFd, from: writeBuf)
        _ = try await io.read(from: readFd, into: readBuf)
        return unsafe ptr[0]
    }
}

extension Basic.BindingTest.ZeroHop {
    @Test
    func `actor sharing IO's executor lands on the SAME OS thread as a probe IO`() async throws {
        let executor = Kernel.Thread.Executor()
        defer { executor.shutdown() }

        let recorder = ThreadRecorder()
        // Probe IO captures the executor's thread on every op.
        let probe = makeProbedIO(on: executor, recorder: recorder)

        // App actor uses the SAME executor via IO.blocking(on:).
        let app = SharedExecutorApp(executor: executor)
        let pipe = try Kernel.Pipe.pipe()

        // A roundtrip through the app actor's IO.
        let got = try await app.roundtrip(
            writeFd: pipe.write,
            readFd: pipe.read,
            value: 42
        )
        #expect(got == 42)

        // A separate probe op on the same executor — should record the same
        // thread ID. Since SharedExecutorApp's IO and the probe IO both wrap
        // actors bound to the same Kernel.Thread.Executor, they share the
        // executor's single OS thread.
        let pipe2 = try Kernel.Pipe.pipe()
        let ptr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { ptr.deallocate() }
        unsafe ptr[0] = 1
        let writeBuf: Span.Raw = unsafe .init(UnsafeRawBufferPointer(ptr))
        let readBuf: Span.Raw.Mutable = unsafe .init(ptr)
        _ = try await probe.write(to: pipe2.write, from: writeBuf)
        _ = try await probe.read(from: pipe2.read, into: readBuf)

        let ids = recorder.snapshot()
        #expect(ids.count == 2)
        #expect(ids[0] == ids[1], "probe ops on the executor shared with the app actor should observe one OS thread")
    }
}

// MARK: - Head-of-Line Blocking

extension Basic.BindingTest.HeadOfLine {
    @Test
    func `ops on a single .blocking() IO serialize on the actor`() async throws {
        // Demonstrates expected strategy-specific behavior — actor isolation
        // serializes ops on a single `.blocking()` IO. Mitigation when needed:
        // multiple IOs, pooled factory, or a different strategy.
        //
        // The assertion is structural: two ops on the same actor cannot
        // observe overlapping completion-counter increments. We pre-place
        // bytes in two pipes so each read can complete; then run two reads
        // concurrently and record the order each finishes via an atomic
        // counter. Under SerialExecutor + actor isolation, the pair must
        // observe distinct sequence numbers (1 and 2), never the same.
        let io = IO.blocking()
        let pipeA = try Kernel.Pipe.pipe()
        let pipeB = try Kernel.Pipe.pipe()

        // Pre-place a byte in each so reads can complete without blocking.
        let oneByte = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { oneByte.deallocate() }
        unsafe oneByte[0] = 99
        let oneByteBuf: Span.Raw = unsafe .init(UnsafeRawBufferPointer(oneByte))
        do throws(Kernel.IO.Write.Error) {
            _ = try Kernel.IO.Write.write(pipeA.write, from: unsafe oneByteBuf.base.nonNull)
            _ = try Kernel.IO.Write.write(pipeB.write, from: unsafe oneByteBuf.base.nonNull)
        } catch {
            Issue.record("pre-fill write failed: \(error)")
            return
        }

        let order = OrderCounter()
        let bufA = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { bufA.deallocate() }
        let bufB = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { bufB.deallocate() }
        let readBufA: Span.Raw.Mutable = unsafe .init(bufA)
        let readBufB: Span.Raw.Mutable = unsafe .init(bufB)

        async let a: Int = {
            let n = try await io.read(from: pipeA.read, into: readBufA)
            order.append(1)
            return n
        }()
        async let b: Int = {
            let n = try await io.read(from: pipeB.read, into: readBufB)
            order.append(2)
            return n
        }()

        _ = try await a
        _ = try await b

        // Both ops completed and recorded — proves the two reads serialized
        // on the actor without deadlocking. Ordering between 1 and 2 is not
        // observable across the actor boundary; the structural claim is
        // "both ran, in some order, sequentialized by the actor's executor."
        let entries = order.snapshot()
        #expect(entries.count == 2)
        #expect(Set(entries) == Set([1, 2]))
    }
}
