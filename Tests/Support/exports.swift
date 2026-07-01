//
//  exports.swift
//  IO Test Support
//
//  Re-exports that test code should see. The Basic domain lives here
//  (not in a production target) — it parameterizes `IO<Basic.Capabilities>`
//  for tests while downstream production packages (swift-file-system,
//  swift-sockets, swift-server) define their own domain Capabilities.
//

@_exported public import IO
@_exported public import IO_Primitives
@_exported public import Kernel
@_exported public import Kernel_Test_Support
@_exported public import Thread_Actor
@_exported public import Memory_Primitives
@_exported public import Buffer_Primitives
@_exported public import Synchronization
