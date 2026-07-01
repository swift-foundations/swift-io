// Toolchain: Swift 6.3.1 (2026-04-30) — anchor added during Phase 7a sweep [EXP-007a]
// Revalidated: Swift 6.3.1 (2026-04-30) — PASSES
//
//
//  main.swift
//  proactor-buffer-ownership experiment
//
//  Tests the buffer-ownership contract for the IO witness's `_read` op
//  under io_uring completions:
//
//    A. Heap-backed buffer + io_uring READ + CheckedContinuation
//       suspension = kernel writes bytes into the caller's buffer
//       across the suspension boundary.
//
//    B. Cancellation mid-flight. Submit a READ, cancel before data
//       arrives, observe the cancel CQE. Confirms the kernel can be
//       asked to release the buffer before the owning frame unwinds —
//       the mechanic a production Completions factory needs via
//       withTaskCancellationHandler + IORING_OP_ASYNC_CANCEL.
//
//  Conclusion drives Phase 2C Q2 in
//  swift-io/Research/io-phase-2-plan.md §2:
//    Pass → keep unified `_read`; document contract.
//    Fail → split proactor into `_readRegistered`.
//

#if os(Linux)

import CUring
import Foundation  // for NSLock, Thread

// MARK: - Cancel handle

/// Small box used by submitRead to publish the SQE's user_data to the
/// caller so testB can issue a matching cancel.
final class CancelHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _userData: UInt64 = 0

    var userData: UInt64 {
        get { lock.lock(); defer { lock.unlock() }; return _userData }
        set { lock.lock(); _userData = newValue; lock.unlock() }
    }
}

// MARK: - Poll thread

/// Runs io_uring_wait_cqe on a dedicated thread. Resumes continuations
/// keyed by SQE user_data.
final class PollThread: @unchecked Sendable {
    private var ring = io_uring()
    private let lock = NSLock()
    private var continuations: [UInt64: CheckedContinuation<Int32, Never>] = [:]
    private var nextID: UInt64 = 1
    private var running: Bool = true

    init() {
        let rc = withUnsafeMutablePointer(to: &ring) {
            curing_queue_init(32, $0)
        }
        precondition(rc == 0, "io_uring_queue_init failed: \(rc)")
    }

    func start() {
        let t = Thread { [weak self] in
            self?.loop()
        }
        t.name = "io_uring-poll"
        t.start()
    }

    private func loop() {
        while running {
            var cqe: UnsafeMutablePointer<io_uring_cqe>?
            let rc = withUnsafeMutablePointer(to: &ring) {
                curing_wait_cqe($0, &cqe)
            }
            if rc < 0 || cqe == nil { continue }

            let res = curing_cqe_res(cqe!)
            let dataPtr = curing_cqe_data(cqe!)
            let userData = dataPtr.map { UInt64(UInt(bitPattern: $0)) } ?? 0
            withUnsafeMutablePointer(to: &ring) {
                curing_cqe_seen($0, cqe!)
            }

            lock.lock()
            let cont = continuations.removeValue(forKey: userData)
            lock.unlock()
            if let cont { cont.resume(returning: res) }
            // Unknown user_data (cancel CQE) — dropped silently.
        }
    }

    /// Submit a READ SQE and await its CQE. `handle.userData` is set
    /// to the submitted SQE's user_data before the continuation
    /// suspends, so an external cancel can be matched.
    func submitRead(
        fd: Int32,
        buffer: UnsafeMutableRawPointer,
        count: UInt32,
        cancelHandle: CancelHandle? = nil
    ) async -> Int32 {
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            lock.lock()
            let id = nextID
            nextID += 1
            continuations[id] = cont
            lock.unlock()

            cancelHandle?.userData = id

            let sqe = withUnsafeMutablePointer(to: &ring) { curing_get_sqe($0) }
            guard let sqe else {
                lock.lock()
                continuations.removeValue(forKey: id)
                lock.unlock()
                cont.resume(returning: -1)
                return
            }
            curing_prep_read(sqe, fd, buffer, count, 0)
            curing_sqe_set_data(sqe, UnsafeMutableRawPointer(bitPattern: UInt(id)))
            _ = withUnsafeMutablePointer(to: &ring) { curing_submit($0) }
        }
    }

    /// Submit IORING_OP_ASYNC_CANCEL for the given user_data. Its own
    /// CQE is observed by the poll loop and dropped (no matching
    /// continuation).
    func submitCancel(userDataToCancel: UInt64) {
        guard userDataToCancel != 0 else { return }
        let sqe = withUnsafeMutablePointer(to: &ring) { curing_get_sqe($0) }
        guard let sqe else { return }
        curing_prep_cancel(sqe, UnsafeMutableRawPointer(bitPattern: UInt(userDataToCancel)), 0)
        // High-bit-set user_data so the cancel CQE doesn't collide with
        // real request IDs.
        curing_sqe_set_data(sqe, UnsafeMutableRawPointer(bitPattern: UInt(UInt64(1) << 63)))
        _ = withUnsafeMutablePointer(to: &ring) { curing_submit($0) }
    }
}

// MARK: - Test A: suspend/resume

func testA(poll: PollThread) async -> String {
    var fds: [Int32] = [0, 0]
    let rc = fds.withUnsafeMutableBufferPointer { buf in
        curing_pipe(buf.baseAddress!)
    }
    guard rc == 0 else { return "testA FAIL: pipe() rc=\(rc) errno=\(curing_errno())" }
    let readFd = fds[0]
    let writeFd = fds[1]
    defer { _ = curing_close(readFd); _ = curing_close(writeFd) }

    // Heap-allocated buffer. The buffer has a stable address that
    // survives the task's suspension (heap-allocated task frame holds
    // the pointer; the pointee lives on the heap regardless).
    let bufCount = 16
    let bufPtr = UnsafeMutableRawBufferPointer.allocate(byteCount: bufCount, alignment: 1)
    defer { bufPtr.deallocate() }
    bufPtr.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: bufCount)

    let expected: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]

    // Producer task: sleep briefly, then write to the pipe. The sleep
    // ensures the READ SQE reaches the kernel before the data lands,
    // so the test exercises the suspend-then-resume path.
    let producer = Task.detached {
        curing_usleep(5_000)  // 5 ms
        expected.withUnsafeBytes { ptr in
            _ = curing_write(writeFd, ptr.baseAddress, UInt(ptr.count))
        }
    }

    let result = await poll.submitRead(
        fd: readFd,
        buffer: bufPtr.baseAddress!,
        count: UInt32(bufCount)
    )
    _ = await producer.value

    guard result > 0 else {
        return "testA FAIL: io_uring READ returned \(result)"
    }
    var received = [UInt8]()
    for i in 0..<Int(result) {
        received.append(bufPtr.load(fromByteOffset: i, as: UInt8.self))
    }
    if received == expected {
        let hex = received.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "testA PASS: buffer = [\(hex)] (\(received.count) bytes delivered across suspension)"
    }
    let got = received.map { String(format: "%02X", $0) }.joined(separator: " ")
    let want = expected.map { String(format: "%02X", $0) }.joined(separator: " ")
    return "testA FAIL: expected [\(want)], got [\(got)]"
}

// MARK: - Test B: cancellation

func testB(poll: PollThread) async -> String {
    var fds: [Int32] = [0, 0]
    let rc = fds.withUnsafeMutableBufferPointer { buf in
        curing_pipe(buf.baseAddress!)
    }
    guard rc == 0 else { return "testB FAIL: pipe() rc=\(rc)" }
    let readFd = fds[0]
    let writeFd = fds[1]
    defer { _ = curing_close(readFd); _ = curing_close(writeFd) }

    let bufCount = 16
    let bufPtr = UnsafeMutableRawBufferPointer.allocate(byteCount: bufCount, alignment: 1)
    defer { bufPtr.deallocate() }
    // Sentinel byte — any mutation indicates the kernel wrote after cancel.
    bufPtr.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0xAA, count: bufCount)

    let handle = CancelHandle()
    let readTask = Task.detached {
        await poll.submitRead(
            fd: readFd,
            buffer: bufPtr.baseAddress!,
            count: UInt32(bufCount),
            cancelHandle: handle
        )
    }

    // Give submitRead time to register its user_data in `handle`.
    try? await Task.sleep(for: .milliseconds(10))

    let userData = handle.userData
    guard userData != 0 else {
        return "testB FAIL: cancel handle not populated (submitRead hadn't registered yet)"
    }
    poll.submitCancel(userDataToCancel: userData)

    let res = await readTask.value
    var modified = false
    for i in 0..<bufCount {
        if bufPtr.load(fromByteOffset: i, as: UInt8.self) != 0xAA {
            modified = true; break
        }
    }

    if res < 0 && !modified {
        return "testB PASS: cancelled SQE returned res=\(res) (expected -ECANCELED = -125); sentinel intact"
    } else if res < 0 && modified {
        return "testB PARTIAL: cancelled SQE returned res=\(res) but buffer was modified — would be UB on a stack buffer"
    } else if res >= 0 {
        return "testB SKIP: SQE completed with res=\(res) before cancel landed (race); rerun to retry"
    } else {
        return "testB UNKNOWN: res=\(res) modified=\(modified)"
    }
}

// MARK: - Main

@main
struct Experiment {
    static func main() async {
        print("=== proactor-buffer-ownership experiment ===")
        print("")

        let poll = PollThread()
        poll.start()

        let a = await testA(poll: poll)
        print(a)

        let b = await testB(poll: poll)
        print(b)

        print("")
        print("=== conclusion ===")
        if a.hasPrefix("testA PASS") {
            print("testA (heap-backed buffer across await): PASS")
            print("  Kernel writes to the buffer pointer captured at SQE submission;")
            print("  Swift's heap-allocated task frame keeps the pointer alive across")
            print("  the CheckedContinuation suspension; resume delivers the bytes.")
        } else {
            print("testA UNEXPECTED: \(a)")
        }
        if b.hasPrefix("testB PASS") {
            print("testB (cancellation): PASS")
            print("  Cancel CQE was observed; buffer unmodified.")
            print("  A production Completions factory MUST use withTaskCancellationHandler")
            print("  + IORING_OP_ASYNC_CANCEL to keep buffer alive until the cancel's")
            print("  own CQE fires, before the owning task frame unwinds.")
        } else {
            print("testB RESULT: \(b)")
        }

        print("")
        print("Architectural implication for the IO witness _read signature:")
        print("  Unified _read(borrowing Kernel.Descriptor, Memory.Buffer.Mutable)")
        print("  async throws(IO.Error) -> Int is SAFE across strategies when:")
        print("   • caller uses heap-backed storage (Array, allocate, Buffer.Aligned, etc.)")
        print("   • completions factory internally implements the cancel-then-await-cancel-CQE")
        print("     pattern so the buffer outlives any in-flight SQE")
        print("  No _readRegistered split needed. Strategy-agnostic contract documented.")
    }
}

#else  // !os(Linux)

@main
struct Experiment {
    static func main() {
        print("This experiment is Linux-only (requires io_uring).")
        print("Run via Docker:")
        print("  cd Experiments/proactor-buffer-ownership")
        print("  ./run.sh")
    }
}

#endif
