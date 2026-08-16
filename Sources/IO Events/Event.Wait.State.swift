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
            private let registration: Mutex<Kernel.Descriptor?>
            private let execution: Mutex<Kernel.Descriptor?>
            private let admissionFailure = Mutex<Event.Failure?>(nil)
            let interest: Kernel.Event.Interest
            let readiness: Async.Channel<Kernel.Event>.Unbounded.Sender
            let completion: Async.Channel<Void>.Unbounded.Sender

            init(
                registration: consuming Kernel.Descriptor,
                execution: consuming Kernel.Descriptor,
                interest: Kernel.Event.Interest,
                readiness: Async.Channel<Kernel.Event>.Unbounded.Sender,
                completion: Async.Channel<Void>.Unbounded.Sender
            ) {
                self.registration = Mutex(.some(consume registration))
                self.execution = Mutex(.some(consume execution))
                self.interest = interest
                self.readiness = readiness
                self.completion = completion
            }
        }
    }

    extension Event.Wait.State {
        var isCancelled: Bool {
            cancelled.load(ordering: .acquiring)
        }

        var failure: Event.Failure? {
            admissionFailure.withLock { $0 }
        }

        func claimRegistration() -> Kernel.Descriptor? {
            registration.withLock { descriptor in descriptor.take() }
        }

        func fail(_ failure: Event.Failure) {
            admissionFailure.withLock { current in
                if current == nil { current = failure }
            }
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
