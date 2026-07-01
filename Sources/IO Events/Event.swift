//
//  Event.swift
//  swift-io
//

@_exported public import Kernel

/// Top-level namespace for the swift-io events-strategy runtime
/// (kqueue/epoll reactor).
///
/// Top-level typealias adoption of `Kernel.Event`: `Event` IS
/// `Kernel.Event`. The adoption provides `Event.Interest`, `Event.ID`,
/// `Event.Options` naturally from the kernel primitive. The IO Events
/// target adds the L3 runtime — ``Event/Actor``, ``Event/Error``,
/// ``Event/Failure``, ``Event/RetryDecision`` — via extensions on the
/// aliased type.
///
/// ## Domain Independence
///
/// This module is strategy-only. It knows nothing about any specific
/// domain's capability set or error taxonomy. Per-domain factories
/// (e.g., `IO<Basic.Capabilities>.events(on:)`) live in the domain's
/// own module and handle the domain-specific error mapping from
/// ``Event/Failure``.
public typealias Event = Kernel.Event
