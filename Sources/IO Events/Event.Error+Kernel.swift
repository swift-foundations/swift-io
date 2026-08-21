#if !os(Windows)
    extension Kernel.IO.Read.Error {

        @usableFromInline
        package var eventError: Event.Error {
            if code == .POSIX.EPIPE {
                return .readClosed
            }
            return .platform(code)
        }
    }

    extension Kernel.IO.Write.Error {

        @usableFromInline
        package var eventError: Event.Error {
            if code == .POSIX.EPIPE {
                return .writeClosed
            }
            return .platform(code)
        }
    }

#endif
