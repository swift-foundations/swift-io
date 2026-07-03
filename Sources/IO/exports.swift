//
//  exports.swift
//  swift-io
//

@_exported public import IO_Completions
@_exported public import IO_Events
// `import IO` gives access to the strategy runtimes (Event / Completion
// actors) and the host-adaptive selector. Domain packages define their
// own Capabilities and compose per-strategy factories on top.
@_exported public import IO_Primitives
