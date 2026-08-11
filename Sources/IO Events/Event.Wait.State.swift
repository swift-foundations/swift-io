//
//  Event.Wait.State.swift
//  swift-io
//

#if !os(Windows)
    import Async
    import Synchronization

    extension Event.Wait {
        /// Shared cancellation and owned execution state for one registration.
        final class State: Sendable {
            private let cancelled = Atomic<Bool>(false)
            private let execution: Mutex<Kernel.Descriptor?>
            let readiness: Async.Channel<Kernel.Event>.Unbounded.Sender
            let completion: Async.Channel<Void>.Unbounded.Sender

            init(
                execution: consuming Kernel.Descriptor,
                readiness: Async.Channel<Kernel.Event>.Unbounded.Sender,
                completion: Async.Channel<Void>.Unbounded.Sender
            ) {
                self.execution = Mutex(.some(consume execution))
                self.readiness = readiness
                self.completion = completion
            }
        }
    }

    extension Event.Wait.State {
        var isCancelled: Bool {
            cancelled.load(ordering: .acquiring)
        }

        func cancel() {
            cancelled.store(true, ordering: .releasing)
            readiness.close()
        }

        func claim() -> Kernel.Descriptor? {
            execution.withLock { descriptor in descriptor.take() }
        }

        func complete() {
            completion.send(())
            completion.close()
        }
    }
#endif
