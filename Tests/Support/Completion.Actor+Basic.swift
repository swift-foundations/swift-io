#if !os(Windows)

    public import IO
    public import Kernel
    public import Memory_Primitives
    public import Span_Raw_Primitives

    extension Completion.Actor {

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

        public func close(_ fd: consuming Kernel.Descriptor) async {
            do throws(Kernel.Close.Error) {
                try Kernel.Close.close(consume fd)
            } catch {

            }
        }

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
