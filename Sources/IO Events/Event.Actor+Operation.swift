//
//  Event.Actor+Operation.swift
//  swift-io
//

#if !os(Windows)
    @_spi(Syscall) import Kernel

    extension Event.Actor {
        /// Waits for readiness and performs one structured nonblocking attempt.
        ///
        /// The descriptor is borrowed throughout. Cancellation wakes the
        /// actor's event source, removes the exact waiter, and deregisters this
        /// operation's distinct Kernel registration. A successful readiness
        /// wait transfers the caller's operation and capture region exactly
        /// once into `Kernel.Thread.run`; that function physically joins its
        /// thread before this method deregisters and returns.
        ///
        /// The operation must be a nonblocking attempt appropriate for the
        /// supplied readiness interest. An arbitrary blocking syscall is not a
        /// supported strategy: Kernel deliberately exposes no generic control
        /// law capable of interrupting one. Blocking work must use a different,
        /// explicitly non-cancellable capability.
        ///
        /// - Parameters:
        ///   - descriptor: Descriptor borrowed until cleanup and join finish.
        ///   - interest: Readiness required before the attempt is invoked.
        ///   - operation: Nonescaping operation transferred once to the
        ///     structured Kernel thread.
        /// - Returns: The operation's sending result after physical join and
        ///   exact deregistration.
        public func run<
            Output: ~Copyable,
            Failure: Swift.Error
        >(
            borrowing descriptor: borrowing Kernel.Descriptor,
            interest: Kernel.Event.Interest,
            operation: sending (borrowing Kernel.Descriptor) throws(Failure) -> sending Output
        ) async throws(Event.Operation.Error<Failure>) -> sending Output {
            // Kernel.Event.Source deliberately takes consuming ownership of
            // each registration descriptor so deregistration can close that
            // exact kernel resource. This duplicate is therefore the event
            // registration itself, not a lifetime escape for the operation:
            // it is deregistered before this borrowed method returns.
            let registered: Kernel.Descriptor
            do throws(Kernel.Descriptor.Duplicate.Error) {
                registered = try Kernel.Descriptor.Duplicate.duplicate(descriptor)
            } catch {
                switch error {
                case .handle:
                    throw .event(.invalidDescriptor)
                case .tooManyOpen:
                    throw .event(.platform(.POSIX.EMFILE))
                case .platform(let failure):
                    throw .event(.platform(failure.code))
                }
            }

            let registrationID: Event.ID
            do throws(Kernel.Event.Driver.Error) {
                registrationID = try polling.source.register(
                    descriptor: consume registered,
                    interest: interest
                )
            } catch {
                throw .event(Event.Error(error))
            }

            registrations[registrationID] = Registration()

            do throws(Event.Operation.Error<Failure>) {
                do throws(Event.Failure) {
                    try await wait(for: registrationID, interest: interest)
                } catch {
                    throw Event.Operation.Error(error)
                }

                let output: Output
                do throws(Kernel.Thread.Run.Error<Failure>) {
                    output = try Kernel.Thread.run(descriptor, operation)
                } catch {
                    switch error {
                    case .creation(let failure), .join(let failure):
                        throw Event.Operation.Error<Failure>.thread(failure)
                    case .operation(let failure):
                        throw Event.Operation.Error<Failure>.operation(failure)
                    }
                }

                do throws(Event.Error) {
                    try deregisterOperation(registrationID)
                } catch {
                    throw Event.Operation.Error<Failure>.event(error)
                }
                return output
            } catch {
                do throws(Event.Error) {
                    try deregisterOperation(registrationID)
                } catch {
                    throw Event.Operation.Error<Failure>.event(error)
                }
                throw error
            }
        }

        /// Removes this operation's exact registration and closes any waiter.
        private func deregisterOperation(
            _ registrationID: Event.ID
        ) throws(Event.Error) {
            if let registration = registrations.removeValue(forKey: registrationID) {
                registration.senders.closeAll()
            }
            do throws(Kernel.Event.Driver.Error) {
                try polling.source.deregister(id: registrationID)
            } catch {
                throw Event.Error(error)
            }
        }
    }

    extension Event.Operation.Error {
        /// Maps the existing actor lifecycle envelope without erasing either
        /// the event error or the caller's operation failure.
        fileprivate init(_ failure: Event.Failure) {
            switch failure {
            case .left(let lifecycle):
                self = .lifecycle(lifecycle)
            case .right(let event):
                self = .event(event)
            }
        }
    }
#endif
