import IO_Test_Support
import Testing

extension Basic.Error {
    @Suite struct Test {
        @Suite struct Unit {}
    }
}

extension Basic.Error.Test.Unit {
    @Test
    func `broken pipe kernel errors map to the domain error`() {
        #if os(Windows)
            let read: Kernel.IO.Read.Error = .platform(.init(code: .Windows.ERROR_BROKEN_PIPE))
            let write: Kernel.IO.Write.Error = .platform(.init(code: .Windows.ERROR_BROKEN_PIPE))
        #else
            let read: Kernel.IO.Read.Error = .platform(.init(code: .POSIX.EPIPE))
            let write: Kernel.IO.Write.Error = .platform(.init(code: .POSIX.EPIPE))
        #endif

        #expect(read.basicError == .brokenPipe)
        #expect(write.basicError == .brokenPipe)
    }
}
