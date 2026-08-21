import Kernel

extension Kernel.IO.Read.Error {

    @usableFromInline
    package var basicError: Basic.Error {
        let brokenPipe: Error_Primitives.Error.Code
        #if os(Windows)
            brokenPipe = .Windows.ERROR_BROKEN_PIPE
        #else
            brokenPipe = .POSIX.EPIPE
        #endif
        if code == brokenPipe {
            return .brokenPipe
        }
        return .platform(code)
    }
}

extension Kernel.IO.Write.Error {

    @usableFromInline
    package var basicError: Basic.Error {
        let brokenPipe: Error_Primitives.Error.Code
        #if os(Windows)
            brokenPipe = .Windows.ERROR_BROKEN_PIPE
        #else
            brokenPipe = .POSIX.EPIPE
        #endif
        if code == brokenPipe {
            return .brokenPipe
        }
        return .platform(code)
    }
}
