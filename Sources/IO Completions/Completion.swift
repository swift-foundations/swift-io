//
//  Completion.swift
//  swift-io
//
//  Namespace adoption: top-level `Completion` IS `Kernel.Completion`.
//  Every nested kernel type — Driver, Submission, Event, Token,
//  Capabilities, Error — is inherited from the kernel layer. The IO
//  Completions target adds L3 composition (Actor, Entry, Cancellation,
//  Handle) via extensions on the aliased type.
//
//  Parallel to `Event = Kernel.Event` in IO Events.
//

@_exported public import Kernel_Completion

/// Top-level namespace for the swift-io completions-strategy runtime
/// (io_uring proactor).
///
/// ## Domain Independence
///
/// This module is strategy-only. It knows nothing about any specific
/// domain's capability set or error taxonomy. Per-domain factories
/// (e.g., `IO<Basic.Capabilities>.completions(on:)`) live in the
/// domain's own module and handle the domain-specific error mapping.
public typealias Completion = Kernel.Completion
