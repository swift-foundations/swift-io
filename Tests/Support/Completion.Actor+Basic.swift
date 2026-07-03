//
//  Completion.Actor+Basic.swift
//  IO Test Support
//
//  Basic-domain (fd byte-ops) operations on the completions-strategy
//  actor. Built on the proactor primitive `submit(_:descriptor:mapEvent:)`
//  from swift-io's IO Completions module. Each domain (Basic, File,
//  Socket, Server) contributes its own extensions here; the proactor
//  itself stays domain-agnostic.
//

#if !os(Windows)

    public import IO
    public import Kernel
    public import Memory_Primitives
    public import Span_Raw_Primitives

    extension Completion.Actor {

        /// Read bytes from fd into buffer via `IORING_OP_READ`.
        public func read(
            from fd: borrowing Kernel.Descriptor,
            into buffer: Span.Raw.Mutable
        ) async throws(Completion.Failure) -> Int {
            let raw = unsafe buffer.base.nonNull

            let descriptor: Kernel.Descriptor?
            do throws(Kernel.Descriptor.Duplicate.Error) {
                descriptor = try Kernel.Descriptor.Duplicate.duplicate(fd)
            } catch {
                throw error.completionFailure
            }

            let address = unsafe Memory.Address(raw.baseAddress!)
            let length: Memory.Address.Count = buffer.count.retag(Memory.self)

            return try await submit(
                .read(address: address, length: length, offset: nil),
                descriptor: consume descriptor
            ) { event throws(Completion.Failure) in
                if let error = event.result.failure { throw error.completionFailure }
                return Int(event.result.value!)
            }
        }

        /// Write bytes from buffer to fd via `IORING_OP_WRITE`.
        public func write(
            to fd: borrowing Kernel.Descriptor,
            from buffer: Span.Raw
        ) async throws(Completion.Failure) -> Int {
            let raw = unsafe buffer.base.nonNull

            let descriptor: Kernel.Descriptor?
            do throws(Kernel.Descriptor.Duplicate.Error) {
                descriptor = try Kernel.Descriptor.Duplicate.duplicate(fd)
            } catch {
                throw error.completionFailure
            }

            let address = unsafe Memory.Address(raw.baseAddress!)
            let length: Memory.Address.Count = buffer.count.retag(Memory.self)

            return try await submit(
                .write(address: address, length: length, offset: nil),
                descriptor: consume descriptor
            ) { event throws(Completion.Failure) in
                if let error = event.result.failure { throw error.completionFailure }
                return Int(event.result.value!)
            }
        }

        /// Close fd synchronously (`close(2)`); consistent with the
        /// blocking and events strategies.
        public func close(_ fd: consuming Kernel.Descriptor) async {
            do throws(Kernel.Close.Error) {
                try Kernel.Close.close(consume fd)
            } catch {
                // Swallow — close errors are rarely actionable; the fd is
                // closed at the kernel level regardless.
            }
        }

        /// Wait for fd readiness via `IORING_OP_POLL_ADD`.
        public func ready(
            from fd: borrowing Kernel.Descriptor,
            interest: Kernel.Event.Interest
        ) async throws(Completion.Failure) {
            let descriptor: Kernel.Descriptor?
            do throws(Kernel.Descriptor.Duplicate.Error) {
                descriptor = try Kernel.Descriptor.Duplicate.duplicate(fd)
            } catch {
                throw error.completionFailure
            }

            _ = try await submit(
                .readiness(events: interest),
                descriptor: consume descriptor
            ) { event throws(Completion.Failure) in
                if let error = event.result.failure { throw error.completionFailure }
            }
        }
    }

#endif
