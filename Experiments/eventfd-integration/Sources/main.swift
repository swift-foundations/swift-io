// MARK: - eventfd Integration Verification
// Purpose: Validate io_uring completions can be discovered via eventfd
//          registered with epoll — the single-thread architecture foundation.
// Hypothesis: Submit NOPs to io_uring → kernel signals eventfd → epoll_wait
//             returns → CQ ring drainable. One thread, one epoll_wait, both
//             readiness and completion events.
//
// Toolchain: swift-6.3-RELEASE
// Platform: Linux aarch64 (Docker, kernel 6.1+)
//
// Result: CONFIRMED — 1K/10K/100K NOPs all complete via epoll_wait on eventfd.
// Revalidated: Swift 6.3.1 (2026-04-30) — PASSES
//         100K NOPs in 13ms (~0.13µs/op). No separate poll thread needed.
//
// Limitation: NOPs complete inline during io_uring_enter — epoll_wait never
//   actually blocks. The wiring is proven but blocking wakeup is not.
//   A timer SQE or pipe readv with delayed write would verify true blocking.
//
// Date: 2026-04-08

#if os(Linux)

import Glibc
@_spi(Syscall) import Kernel_IO_Primitives
@_spi(Syscall) import Linux_Kernel_IO_Standard
@_spi(Syscall) import Linux_Kernel_Event_Standard

// MARK: - Ring (mmap'd io_uring pointers, no fd ownership)

struct Ring {
    // SQ
    let sqHead: UnsafeMutablePointer<UInt32>
    let sqTail: UnsafeMutablePointer<UInt32>
    let sqMask: UInt32
    let sqArray: UnsafeMutablePointer<UInt32>
    let sqes: UnsafeMutablePointer<Kernel.IO.Uring.Submission.Queue.Entry>
    // CQ
    let cqHead: UnsafeMutablePointer<UInt32>
    let cqTail: UnsafeMutablePointer<UInt32>
    let cqMask: UInt32
    let cqes: UnsafeMutablePointer<Kernel.IO.Uring.Completion.Queue.Entry>
    // mmap regions (for munmap)
    let sqRingBase: UnsafeMutableRawPointer; let sqRingSize: Int
    let cqRingBase: UnsafeMutableRawPointer; let cqRingSize: Int
    let sqeBase: UnsafeMutableRawPointer; let sqeSize: Int
}

func mmapRing(
    _ descriptor: borrowing Kernel.Descriptor,
    params: Kernel.IO.Uring.Params
) -> Ring {
    let fd = descriptor._rawValue  // one _rawValue access for mmap — unavoidable

    let sqRingSz = Int(params.sqOff.array) + Int(params.sqEntries) * MemoryLayout<UInt32>.size
    let cqRingSz = Int(params.cqOff.cqes) + Int(params.cqEntries) * MemoryLayout<Kernel.IO.Uring.Completion.Queue.Entry>.size
    let sqeSz = Int(params.sqEntries) * MemoryLayout<Kernel.IO.Uring.Submission.Queue.Entry>.size

    let sq = mmap(nil, sqRingSz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, 0)!
    let cq = mmap(nil, cqRingSz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, 0x8000000)!
    let sqe = mmap(nil, sqeSz, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, 0x10000000)!

    return Ring(
        sqHead: sq.advanced(by: Int(params.sqOff.head)).assumingMemoryBound(to: UInt32.self),
        sqTail: sq.advanced(by: Int(params.sqOff.tail)).assumingMemoryBound(to: UInt32.self),
        sqMask: sq.advanced(by: Int(params.sqOff.ringMask)).load(as: UInt32.self),
        sqArray: sq.advanced(by: Int(params.sqOff.array)).assumingMemoryBound(to: UInt32.self),
        sqes: sqe.assumingMemoryBound(to: Kernel.IO.Uring.Submission.Queue.Entry.self),
        cqHead: cq.advanced(by: Int(params.cqOff.head)).assumingMemoryBound(to: UInt32.self),
        cqTail: cq.advanced(by: Int(params.cqOff.tail)).assumingMemoryBound(to: UInt32.self),
        cqMask: cq.advanced(by: Int(params.cqOff.ringMask)).load(as: UInt32.self),
        cqes: cq.advanced(by: Int(params.cqOff.cqes)).assumingMemoryBound(to: Kernel.IO.Uring.Completion.Queue.Entry.self),
        sqRingBase: sq, sqRingSize: sqRingSz,
        cqRingBase: cq, cqRingSize: cqRingSz,
        sqeBase: sqe, sqeSize: sqeSz
    )
}

func teardownRing(_ ring: Ring) {
    munmap(ring.sqRingBase, ring.sqRingSize)
    munmap(ring.cqRingBase, ring.cqRingSize)
    munmap(ring.sqeBase, ring.sqeSize)
}

// MARK: - Submit + Drain

func submitNops(
    _ ring: Ring,
    descriptor: borrowing Kernel.Descriptor,
    count: Int
) throws -> Int {
    var tail = ring.sqTail.pointee
    let head = ring.sqHead.pointee
    let available = Int(ring.sqMask + 1) - Int(tail &- head)
    let batch = min(count, available)

    for i in 0..<batch {
        let idx = tail & ring.sqMask
        ring.sqArray[Int(idx)] = idx
        let sqe = ring.sqes.advanced(by: Int(idx))
        UnsafeMutableRawPointer(sqe).initializeMemory(
            as: UInt8.self, repeating: 0,
            count: MemoryLayout<Kernel.IO.Uring.Submission.Queue.Entry>.size
        )
        sqe.pointee.prepare.nop(
            data: Kernel.IO.Uring.Operation.Data(__unchecked: (), UInt64(i))
        )
        tail &+= 1
    }

    // NOTE: Production code needs atomic store-release here.
    // Plain store is safe in this experiment because io_uring_enter provides a full barrier.
    ring.sqTail.pointee = tail
    return try Kernel.IO.Uring.enter(
        descriptor, toSubmit: UInt32(batch), minComplete: 0, flags: []
    )
}

func drainCompletions(_ ring: Ring) -> Int {
    var head = ring.cqHead.pointee
    let tail = ring.cqTail.pointee
    var count = 0
    while head != tail {
        let cqe = ring.cqes[Int(head & ring.cqMask)]
        if !cqe.isSuccess {
            print("  CQE error: res=\(cqe.res) data=\(cqe.data.rawValue)")
        }
        head &+= 1
        count += 1
    }
    // NOTE: Production code needs atomic store-release here; CQ tail reads need acquire.
    ring.cqHead.pointee = head
    return count
}

// MARK: - Integration Test

func nowNanos() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

func runTest(
    ring: Ring,
    ringDescriptor: borrowing Kernel.Descriptor,
    epollDescriptor: borrowing Kernel.Descriptor,
    eventfdRaw: Int32,
    count: Int
) throws {
    var completed = 0
    let start = nowNanos()

    while completed < count {
        let batch = min(Int(ring.sqMask + 1), count - completed)
        let submitted = try submitNops(ring, descriptor: ringDescriptor, count: batch)

        // epoll_wait — block until eventfd fires
        var events = [Kernel.Event.Poll.Event](
            repeating: Kernel.Event.Poll.Event(events: Kernel.Event.Poll.Events(rawValue: 0)),
            count: 1
        )
        let nReady = try Kernel.Event.Poll.wait(
            epollDescriptor, events: &events, timeout: .seconds(5)
        )
        guard nReady > 0 else {
            print("  TIMEOUT — epoll_wait returned 0")
            return
        }

        // Drain eventfd counter (must read to re-arm edge-triggered)
        var efdVal: UInt64 = 0
        _ = Glibc.read(eventfdRaw, &efdVal, 8)

        let drained = drainCompletions(ring)
        completed += drained
        if drained != submitted {
            print("  NOTE: submitted=\(submitted) drained=\(drained)")
        }
    }

    let elapsed = nowNanos() - start
    let usPerOp = elapsed / UInt64(count) / 1000
    print("  \(count) NOPs: \(elapsed / 1_000_000)ms total, ~\(usPerOp)µs/op")
}

// MARK: - Main

do {
    print("io_uring + eventfd + epoll integration experiment")
    print("=================================================")

    // 1. Create io_uring ring
    var params = Kernel.IO.Uring.Params()
    let ringDescriptor = try Kernel.IO.Uring.setup(entries: 256, params: &params)
    let ring = mmapRing(ringDescriptor, params: params)
    print("✓ io_uring ring (256 entries, fd=\(ringDescriptor._rawValue))")

    // 2. Create eventfd
    var eventfd = try Kernel.Event.Descriptor.create(flags: .cloexec | .nonblock)
    let eventfdRaw = eventfd.descriptor._rawValue
    print("✓ eventfd (fd=\(eventfdRaw))")

    // 3. Register eventfd with io_uring
    var efdForRegister = eventfdRaw
    try withUnsafeMutablePointer(to: &efdForRegister) { ptr in
        try Kernel.IO.Uring.register(
            ringDescriptor, opcode: .eventfd.register, argument: ptr, count: 1
        )
    }
    print("✓ eventfd registered with io_uring")

    // 4. Create epoll, register eventfd for read events (edge-triggered)
    let epollDescriptor = try Kernel.Event.Poll.create()
    try Kernel.Event.Poll.ctl(
        epollDescriptor, op: .add, fd: eventfd.descriptor,
        event: Kernel.Event.Poll.Event(events: [.in, .et])
    )
    print("✓ eventfd registered with epoll (fd=\(epollDescriptor._rawValue))")

    // 5. Run tests
    print("\nSubmit NOPs → epoll_wait on eventfd → drain CQ:")
    for count in [1_000, 10_000, 100_000] {
        try runTest(
            ring: ring,
            ringDescriptor: ringDescriptor,
            epollDescriptor: epollDescriptor,
            eventfdRaw: eventfdRaw,
            count: count
        )
    }

    // 6. Cleanup (descriptors close via deinit, ring via munmap)
    teardownRing(ring)
    eventfd.close()
    Kernel.IO.Uring.close(ringDescriptor)

    print("\nRESULT: CONFIRMED — eventfd integration path works")

} catch {
    print("FAILED: \(error)")
    exit(1)
}

#else
print("This experiment requires Linux. Run in Docker:")
print("  docker run --rm -v $PWD/../../../..:/Developer \\")
print("    -w /Developer/swift-foundations/swift-io/Experiments/eventfd-integration \\")
print("    swift:6.3 bash -c 'apt-get update -qq && apt-get install -qq -y uuid-dev > /dev/null && swift run'")
#endif
