//
//  Basic.swift
//  swift-io
//

/// Namespace for the basic byte-oriented operations over
/// `Kernel.Descriptor` — the swift-io domain.
///
/// ``Basic`` groups the swift-io-specific types that parameterize the
/// generic ``IO`` bundle for fd-generic byte operations:
/// ``Basic/Capabilities`` (what operations exist) and ``Basic/Error``
/// (the error domain).
///
/// The `IO<Basic.Capabilities>` specialization is constructed by the
/// per-strategy factories (``IO/blocking(on:)``, ``IO/events(on:)``,
/// ``IO/completions(on:)``) and the host-adaptive ``IO/default()``.
public enum Basic {}
