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
        @Suite struct `Shared Executor` {}
        @Suite struct `Zero Hop` {}
        @Suite struct `Head Of Line` {}
    }
}

extension Basic.BindingTest.MandatoryBinding {
    @Test
    func `read survives Task.sleep — actor isolation pins to executor`() async throws {

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

                    let ptr = unsafe UnsafeMutableRawBufferPointer.allocate(
                        byteCount: 1,
                        alignment: 1
                    )
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

private final class ThreadRecorder: Sendable {
    private let storage = Mutex<[Kernel.Thread.ID]>([])
}

extension ThreadRecorder {
    func record(_ id: Kernel.Thread.ID) { storage.withLock { $0.append(id) } }
    func snapshot() -> [Kernel.Thread.ID] { storage.withLock { $0 } }
}

private final class OrderCounter: Sendable {
    private let storage = Mutex<[Int]>([])
}

extension OrderCounter {
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

        }
    )
    let runner = unsafe IO<Basic.Capabilities>.Runner(
        executor: { unsafe actor.unownedExecutor },
        shutdown: {}
    )
    return IO(capabilities: capabilities, runner: runner)
}

extension Basic.BindingTest.`Shared Executor` {
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
        #expect(
            ids[0] == ids[1],
            "ioA write and ioB read on shared executor should observe the same OS thread"
        )
    }

    @Test
    func `two IOs on DIFFERENT executors land on DIFFERENT OS threads (control)`() async throws {

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

        let aIDs = Set([ids[0], ids[2]])
        let bIDs = Set([ids[1], ids[3]])
        #expect(aIDs.count == 1, "ioA's ops should share one thread")
        #expect(bIDs.count == 1, "ioB's ops should share one thread")
        #expect(aIDs.isDisjoint(with: bIDs), "ioA and ioB should be on different threads")
    }
}

actor SharedExecutorApp {
    let executor: Kernel.Thread.Executor
    let io: IO<Basic.Capabilities>

    init(executor: Kernel.Thread.Executor) {
        self.executor = executor
        self.io = IO.blocking(on: executor)
    }
}

extension SharedExecutorApp {
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

extension Basic.BindingTest.`Zero Hop` {
    @Test
    func `actor sharing IO's executor lands on the SAME OS thread as a probe IO`() async throws {
        let executor = Kernel.Thread.Executor()
        defer { executor.shutdown() }

        let recorder = ThreadRecorder()

        let probe = makeProbedIO(on: executor, recorder: recorder)

        let app = SharedExecutorApp(executor: executor)
        let pipe = try Kernel.Pipe.pipe()

        let got = try await app.roundtrip(
            writeFd: pipe.write,
            readFd: pipe.read,
            value: 42
        )
        #expect(got == 42)

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
        #expect(
            ids[0] == ids[1],
            "probe ops on the executor shared with the app actor should observe one OS thread"
        )
    }
}

extension Basic.BindingTest.`Head Of Line` {
    @Test
    func `ops on a single .blocking() IO serialize on the actor`() async throws {

        let io = IO.blocking()
        let pipeA = try Kernel.Pipe.pipe()
        let pipeB = try Kernel.Pipe.pipe()

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

        let entries = order.snapshot()
        #expect(entries.count == 2)
        #expect(Set(entries) == Set([1, 2]))
    }
}
