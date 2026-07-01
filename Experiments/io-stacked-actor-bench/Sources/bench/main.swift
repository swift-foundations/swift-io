// IO Stacked Actor Benchmark — Four-Config Measurement
//
// Resolves Item 6 from HANDOFF-io-layered-implementation-review.md:
//   "Is swift-io's ~3.9 µs actor hop cost (measured in actor-hop-benchmark)
//    an inherent structural ceiling, or does the shared-executor (TCA26)
//    pattern actually eliminate it in realistic stacked use?"
//
// Four configurations, write+read each iteration on a pipe:
//
//   Config 1. Raw Kernel.IO syscall        — no actor, no witness (floor reference)
//   Config 2. Plain actor + Kernel.IO      — isolates actor-hop cost from witness cost
//   Config 3. Shape B IO, unshared         — swift-io default path (cross-hop)
//   Config 4. Shape B IO, shared-executor  — swift-io fast path (TCA26 pattern)
//
// Workload: pipe(2) created once per config. Each iteration writes 4KB to
// the write end and reads 4KB from the read end, same task. Pipe buffer is
// 16–64KB depending on platform, so no iteration blocks on buffer-full.
//
// Measurement: warmup + three trials of N iterations each.
// Each iteration = 1 write + 1 read = 2 ops. Report per-op ns.
//
// Build: swift build -c release
// Run:   .build/release/bench
//
// See RESULTS.md for the measured numbers and interpretation.

import Dispatch
import Foundation
import IO
import IO_Blocking
import Executors
import Kernel
import Memory_Primitives

#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif

// ============================================================================
// MARK: - Configuration
// ============================================================================

let iterations = 50_000      // per trial; each iter = 1 write + 1 read
let warmupIterations = 2_000
let trials = 3
let messageBytes = 4096      // 4KB — fits pipe buffer comfortably

// ============================================================================
// MARK: - Pipe setup
// ============================================================================

// Raw POSIX pipe for Config 1 and 2. Returns (readFd, writeFd).
@inline(never)
func makeRawPipe() -> (Int32, Int32) {
    var fds: (Int32, Int32) = (0, 0)
    let result = unsafe withUnsafeMutablePointer(to: &fds) { (ptr: UnsafeMutablePointer<(Int32, Int32)>) -> Int32 in
        unsafe ptr.withMemoryRebound(to: Int32.self, capacity: 2) { (intPtr: UnsafeMutablePointer<Int32>) -> Int32 in
            unsafe pipe(intPtr)
        }
    }
    precondition(result == 0, "pipe() failed: \(errno)")
    return fds
}

@inline(never)
func closeRawPipe(_ fds: (Int32, Int32)) {
    unsafe close(fds.0)
    unsafe close(fds.1)
}

// ============================================================================
// MARK: - Shared bookkeeping
// ============================================================================

@inline(never)
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

@inline(never)
func blackHole<T>(_ x: T) {
    @inline(never) func sink(_ p: UnsafeRawPointer) {}
    unsafe withUnsafePointer(to: x) { sink(UnsafeRawPointer($0)) }
}

// ============================================================================
// MARK: - Config 1: Raw syscall (floor)
// ============================================================================

@inline(never)
func config1Raw(iters: Int) -> UInt64 {
    let (readFd, writeFd) = makeRawPipe()
    defer { closeRawPipe((readFd, writeFd)) }

    let writeBuf = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: messageBytes, alignment: 8)
    defer { writeBuf.deallocate() }
    unsafe memset(writeBuf.baseAddress!, 42, messageBytes)

    let readBuf = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: messageBytes, alignment: 8)
    defer { readBuf.deallocate() }

    var sink: Int = 0
    let t0 = nowNs()
    for _ in 0..<iters {
        let w = unsafe write(writeFd, writeBuf.baseAddress!, messageBytes)
        let r = unsafe read(readFd, readBuf.baseAddress!, messageBytes)
        sink &+= Int(w) &+ Int(r)
    }
    let t1 = nowNs()
    blackHole(sink)
    return t1 &- t0
}

// ============================================================================
// MARK: - Config 2: Plain actor + raw syscall
// ============================================================================

// Plain actor that owns its pipe fds + buffers. No witness, no swift-io.
// Measures actor hop cost + syscall cost, isolated from witness structure.
actor PlainActor {
    let executor: Kernel.Thread.Executor
    let readFd: Int32
    let writeFd: Int32
    let writeBuf: UnsafeMutableRawBufferPointer
    let readBuf: UnsafeMutableRawBufferPointer
    let size: Int

    init(executor: Kernel.Thread.Executor, messageBytes: Int) {
        self.executor = executor
        self.size = messageBytes

        var fds: (Int32, Int32) = (0, 0)
        let rc = unsafe withUnsafeMutablePointer(to: &fds) { (ptr: UnsafeMutablePointer<(Int32, Int32)>) -> Int32 in
            unsafe ptr.withMemoryRebound(to: Int32.self, capacity: 2) { (intPtr: UnsafeMutablePointer<Int32>) -> Int32 in
                unsafe pipe(intPtr)
            }
        }
        precondition(rc == 0, "pipe() failed: \(errno)")
        self.readFd = fds.0
        self.writeFd = fds.1

        self.writeBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: messageBytes, alignment: 8)
        self.readBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: messageBytes, alignment: 8)
        unsafe memset(self.writeBuf.baseAddress!, 42, messageBytes)
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        unsafe executor.asUnownedSerialExecutor()
    }

    @inline(never)
    func writeOp() -> Int {
        unsafe Foundation.write(writeFd, writeBuf.baseAddress!, size)
    }

    @inline(never)
    func readOp() -> Int {
        unsafe Foundation.read(readFd, readBuf.baseAddress!, size)
    }

    func teardown() {
        unsafe close(readFd)
        unsafe close(writeFd)
        writeBuf.deallocate()
        readBuf.deallocate()
    }
}

@inline(never)
func config2ActorSyscall(actor: PlainActor, iters: Int) async -> UInt64 {
    var sink: Int = 0
    let t0 = nowNs()
    for _ in 0..<iters {
        let w = await actor.writeOp()
        let r = await actor.readOp()
        sink &+= w &+ r
    }
    let t1 = nowNs()
    blackHole(sink)
    return t1 &- t0
}

// ============================================================================
// MARK: - Config 3: Shape B IO, unshared executor (default path)
// ============================================================================

@inline(never)
func config3ShapeBUnshared(io: IO, iters: Int) async throws -> UInt64 {
    let pipe = try Kernel.Pipe.pipe()

    let writePtr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: messageBytes, alignment: 8)
    defer { writePtr.deallocate() }
    unsafe memset(writePtr.baseAddress!, 42, messageBytes)

    let readPtr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: messageBytes, alignment: 8)
    defer { readPtr.deallocate() }

    let writeBuffer = unsafe Memory.Buffer(UnsafeRawBufferPointer(writePtr))
    let readBuffer = unsafe Memory.Buffer.Mutable(readPtr)

    var sink: Int = 0
    let t0 = nowNs()
    for _ in 0..<iters {
        let w = try await io.write(to: pipe.write, from: writeBuffer)
        let r = try await io.read(from: pipe.read, into: readBuffer)
        sink &+= w &+ r
    }
    let t1 = nowNs()
    blackHole(sink)
    return t1 &- t0
}

// ============================================================================
// MARK: - Config 4: Shape B IO, shared-executor (TCA26 fast path)
// ============================================================================

// Consumer actor that forwards its unownedExecutor to IO's executor.
// All calls inside this actor land on IO's executor thread — no hop.
actor SharedConsumer {
    let io: IO

    init(io: IO) {
        self.io = io
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        io.unownedExecutor
    }

    @inline(never)
    func runLoop(
        iters: Int,
        readFd: borrowing Kernel.Descriptor,
        writeFd: borrowing Kernel.Descriptor,
        writeBuffer: Memory.Buffer,
        readBuffer: Memory.Buffer.Mutable
    ) async throws -> (UInt64, Int) {
        var sink: Int = 0
        let t0 = nowNs()
        for _ in 0..<iters {
            let w = try await io.write(to: writeFd, from: writeBuffer)
            let r = try await io.read(from: readFd, into: readBuffer)
            sink &+= w &+ r
        }
        let t1 = nowNs()
        return (t1 &- t0, sink)
    }
}

@inline(never)
func config4ShapeBShared(consumer: SharedConsumer, io: IO, iters: Int) async throws -> UInt64 {
    let pipe = try Kernel.Pipe.pipe()

    let writePtr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: messageBytes, alignment: 8)
    defer { writePtr.deallocate() }
    unsafe memset(writePtr.baseAddress!, 42, messageBytes)

    let readPtr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: messageBytes, alignment: 8)
    defer { readPtr.deallocate() }

    let writeBuffer = unsafe Memory.Buffer(UnsafeRawBufferPointer(writePtr))
    let readBuffer = unsafe Memory.Buffer.Mutable(readPtr)

    let (ns, sink) = try await consumer.runLoop(
        iters: iters,
        readFd: pipe.read,
        writeFd: pipe.write,
        writeBuffer: writeBuffer,
        readBuffer: readBuffer
    )
    blackHole(sink)
    return ns
}

// ============================================================================
// MARK: - Reporting
// ============================================================================

struct TrialResult {
    let name: Swift.String
    let ns: [UInt64]   // one per trial
    let iters: Int     // iterations per trial
    let opsPerIter: Int // ops measured per iteration (1 write + 1 read = 2)

    var meanNsPerOp: Double {
        let totalNs = Double(ns.reduce(0, &+))
        let totalOps = Double(ns.count * iters * opsPerIter)
        return totalNs / totalOps
    }

    var minNsPerOp: Double {
        let minNs = ns.map { Double($0) / Double(iters * opsPerIter) }.min() ?? 0
        return minNs
    }

    var maxNsPerOp: Double {
        let maxNs = ns.map { Double($0) / Double(iters * opsPerIter) }.max() ?? 0
        return maxNs
    }

    var opsPerSec: Double {
        1_000_000_000.0 / meanNsPerOp
    }
}

func printResult(_ r: TrialResult) {
    let padded = r.name.padding(toLength: 38, withPad: " ", startingAt: 0)
    let mean = Swift.String(format: "%8.1f", r.meanNsPerOp)
    let minv = Swift.String(format: "%6.1f", r.minNsPerOp)
    let maxv = Swift.String(format: "%6.1f", r.maxNsPerOp)
    let throughput = Swift.String(format: "%9.0f", r.opsPerSec)
    print("\(padded) \(mean) ns/op  (min \(minv), max \(maxv))   \(throughput) ops/sec")
}

// ============================================================================
// MARK: - Main
// ============================================================================

@main
struct Bench {
    static func main() async throws {
        print("=== io-stacked-actor-bench ===")
        print("iterations per trial: \(iterations) × \(trials) trials")
        print("message size: \(messageBytes) bytes")
        print("ops per iteration: 1 write + 1 read = 2")
        print("")

        // --- Config 1: Raw syscall floor
        print("Config 1: Raw Kernel.IO syscall (no actor, no witness)")
        print("warmup...")
        _ = config1Raw(iters: warmupIterations)
        var ns1: [UInt64] = []
        for i in 1...trials {
            print("  trial \(i)...")
            ns1.append(config1Raw(iters: iterations))
        }
        let r1 = TrialResult(name: "1. raw syscall", ns: ns1, iters: iterations, opsPerIter: 2)
        print("")

        // --- Config 2: Plain actor + raw syscall
        print("Config 2: Plain actor + raw syscall (actor hop + syscall)")
        let c2Executor = Kernel.Thread.Executor()
        defer { c2Executor.shutdown() }
        let plainActor = PlainActor(executor: c2Executor, messageBytes: messageBytes)
        print("warmup...")
        _ = await config2ActorSyscall(actor: plainActor, iters: warmupIterations)
        var ns2: [UInt64] = []
        for i in 1...trials {
            print("  trial \(i)...")
            ns2.append(await config2ActorSyscall(actor: plainActor, iters: iterations))
        }
        let r2 = TrialResult(name: "2. plain actor + syscall", ns: ns2, iters: iterations, opsPerIter: 2)
        print("")

        // --- Config 3: Shape B IO, unshared
        print("Config 3: Shape B IO unshared (io.blocking() default, cross-hop)")
        let c3Executor = Kernel.Thread.Executor()
        defer { c3Executor.shutdown() }
        let io3 = IO.blocking(on: c3Executor)
        print("warmup...")
        _ = try await config3ShapeBUnshared(io: io3, iters: warmupIterations)
        var ns3: [UInt64] = []
        for i in 1...trials {
            print("  trial \(i)...")
            ns3.append(try await config3ShapeBUnshared(io: io3, iters: iterations))
        }
        let r3 = TrialResult(name: "3. Shape B IO unshared", ns: ns3, iters: iterations, opsPerIter: 2)
        print("")

        // --- Config 4: Shape B IO, shared-executor
        print("Config 4: Shape B IO shared-executor (TCA26 pattern)")
        let c4Executor = Kernel.Thread.Executor()
        defer { c4Executor.shutdown() }
        let io4 = IO.blocking(on: c4Executor)
        let consumer = SharedConsumer(io: io4)
        print("warmup...")
        _ = try await config4ShapeBShared(consumer: consumer, io: io4, iters: warmupIterations)
        var ns4: [UInt64] = []
        for i in 1...trials {
            print("  trial \(i)...")
            ns4.append(try await config4ShapeBShared(consumer: consumer, io: io4, iters: iterations))
        }
        let r4 = TrialResult(name: "4. Shape B IO shared", ns: ns4, iters: iterations, opsPerIter: 2)
        print("")

        // --- Summary
        print("=== Results ===")
        print("")
        print("Config                                    mean ns/op  (min, max)         throughput")
        print("---------------------------------------- ----------- -----------------   ----------")
        printResult(r1)
        printResult(r2)
        printResult(r3)
        printResult(r4)
        print("")

        // --- Derived metrics
        let c1 = r1.meanNsPerOp
        let c2 = r2.meanNsPerOp
        let c3 = r3.meanNsPerOp
        let c4 = r4.meanNsPerOp

        print("=== Derived ===")
        print(Swift.String(format: "Actor-hop cost    (C2 − C1): %7.1f ns/op", c2 - c1))
        print(Swift.String(format: "Witness overhead  (C3 − C2): %7.1f ns/op", c3 - c2))
        print(Swift.String(format: "Shared savings    (C3 − C4): %7.1f ns/op", c3 - c4))
        print(Swift.String(format: "Shared vs raw     (C4 ÷ C1):    %.2f×", c4 / c1))
        print(Swift.String(format: "Unshared vs raw   (C3 ÷ C1):    %.2f×", c3 / c1))
        print("")

        // --- Decision tree output
        print("=== Decision tree ===")
        let c4RatioC1 = c4 / c1
        if c4RatioC1 <= 2.0 {
            print("RESULT: C4 ≤ 2× C1 (swift-io with shared-executor within 2× raw).")
            print("→ Commit to Framing E. Shape B's fast path is competitive.")
        } else if c4RatioC1 <= 5.0 {
            print("RESULT: C4 is \(Swift.String(format: "%.1f", c4RatioC1))× C1 (shared-executor helps but not dominant).")
            print("→ Framing E is acceptable; document the ratio as the ceiling.")
        } else {
            print("RESULT: C4 is \(Swift.String(format: "%.1f", c4RatioC1))× C1 (shared-executor significantly slower than raw).")
            print("→ Consider Framing B research note.")
        }

        let witnessOverhead = c3 - c2
        if witnessOverhead < 100 {
            print("Witness overhead C3−C2 = \(Swift.String(format: "%.1f", witnessOverhead)) ns: structurally negligible.")
            print("→ The hop cost is Swift concurrency, not swift-io's witness layering.")
        } else {
            print("Witness overhead C3−C2 = \(Swift.String(format: "%.1f", witnessOverhead)) ns: significant.")
            print("→ Shape B adds measurable cost on top of raw actor hop; Framing B deserves consideration.")
        }
    }
}
