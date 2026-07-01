//
//  Completion.Witness Tests.swift
//  swift-io
//
//  Cross-platform witness-level integration tests for IO Completions.
//  Uses IO.completionsTest() — real io_uring on Linux, kqueue on macOS.
//  Every test does real pipe I/O through the IO witness; the backend
//  is opaque.
//

#if !os(Windows)

import Testing
import IO_Completions_Test_Support
@_spi(Syscall) import Kernel
import Memory_Primitives
import Span_Raw_Primitives

enum ProactorWitnessTests {
    @Suite struct Witness {

        @Suite struct Integration {

            @Test func `pipe read/write round-trip`() async throws {
                let io = try IO.completionsTest()
                let pipe = try Kernel.Pipe.pipe()
                try? Kernel.File.Control.setNonBlocking(pipe.read)

                let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]

                let writePtr = UnsafeMutableRawBufferPointer.allocate(
                    byteCount: payload.count, alignment: 1
                )
                defer { unsafe writePtr.deallocate() }
                for (i, byte) in payload.enumerated() { unsafe writePtr[i] = byte }
                let writeBuffer: Span.Raw = unsafe .init(UnsafeRawBufferPointer(writePtr))

                let written = try await io.write(to: pipe.write, from: writeBuffer)
                #expect(written == payload.count)

                let readPtr = UnsafeMutableRawBufferPointer.allocate(
                    byteCount: 1024, alignment: 1
                )
                defer { unsafe readPtr.deallocate() }
                let readBuffer: Span.Raw.Mutable = unsafe .init(readPtr)

                let n = try await io.read(from: pipe.read, into: readBuffer)
                #expect(n == payload.count)

                var received: [UInt8] = []
                for i in 0..<n { received.append(unsafe readPtr[i]) }
                #expect(received == payload)
            }

            @Test func `ready fires on pre-filled pipe`() async throws {
                let io = try IO.completionsTest()
                let pipe = try Kernel.Pipe.pipe()
                try? Kernel.File.Control.setNonBlocking(pipe.read)

                let oneByte = UnsafeMutableRawBufferPointer.allocate(
                    byteCount: 1, alignment: 1
                )
                defer { unsafe oneByte.deallocate() }
                unsafe oneByte[0] = 0x42

                _ = try await io.write(
                    to: pipe.write,
                    from: unsafe .init(UnsafeRawBufferPointer(oneByte))
                )

                try await io.ready(from: pipe.read, interest: .read)

                let n = try await io.read(
                    from: pipe.read,
                    into: unsafe .init(oneByte)
                )
                #expect(n == 1)
                #expect(unsafe oneByte[0] == 0x42)
            }

            @Test func `ready is single-shot across calls`() async throws {
                let io = try IO.completionsTest()
                let pipe = try Kernel.Pipe.pipe()
                try? Kernel.File.Control.setNonBlocking(pipe.read)

                let oneByte = UnsafeMutableRawBufferPointer.allocate(
                    byteCount: 1, alignment: 1
                )
                defer { unsafe oneByte.deallocate() }

                // Pre-fill with two bytes.
                unsafe oneByte[0] = 0x01
                _ = try await io.write(
                    to: pipe.write,
                    from: unsafe .init(UnsafeRawBufferPointer(oneByte))
                )
                unsafe oneByte[0] = 0x02
                _ = try await io.write(
                    to: pipe.write,
                    from: unsafe .init(UnsafeRawBufferPointer(oneByte))
                )

                // Round 1.
                try await io.ready(from: pipe.read, interest: .read)
                _ = try await io.read(
                    from: pipe.read,
                    into: unsafe .init(oneByte)
                )

                // Round 2 — fresh registration, must fire on remaining data.
                try await io.ready(from: pipe.read, interest: .read)
                _ = try await io.read(
                    from: pipe.read,
                    into: unsafe .init(oneByte)
                )
            }

            @Test func `close completes without error`() async throws {
                let io = try IO.completionsTest()
                let pipe = try Kernel.Pipe.pipe()
                let duped = try Kernel.Descriptor.Duplicate.duplicate(pipe.write)
                await io.close(consume duped)
            }
        }

        // Cancel handshake requires real kernel to produce -ECANCELED CQE.
        #if os(Linux)
        @Suite struct `Cancel Handshake` {

            @Test func `read on empty pipe returns after cancel CQEs`() async throws {
                let io = try IO.completionsTest()

                let task = Task {
                    let pipe = try Kernel.Pipe.pipe()
                    let readPtr = UnsafeMutableRawBufferPointer.allocate(
                        byteCount: 16, alignment: 1
                    )
                    defer { unsafe readPtr.deallocate() }
                    return try await io.read(
                        from: pipe.read,
                        into: unsafe .init(readPtr)
                    )
                }

                try await Task.sleep(for: .milliseconds(10))
                task.cancel()

                do {
                    _ = try await task.value
                } catch {
                    _ = error
                }
            }
        }
        #endif
    }
}

#endif
