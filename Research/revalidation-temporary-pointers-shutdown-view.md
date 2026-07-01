# Revalidation: TemporaryPointers warning in ~Escapable shutdown views

**Date**: 2026-04-06
**Swift version**: Apple Swift 6.3 (swiftlang-6.3.0.123.5 clang-2100.0.123.102)
**Target**: arm64-apple-macosx26.0

## Workaround

`IO.Event.Channel.Shutdown` and `IO.Stream.Shutdown` are `~Copyable, ~Escapable`
view types that need mutating access to their parent. Swift has no stored `inout`
reference, so both use `UnsafeMutablePointer<T>` initialized from `&parent`:

```swift
@_lifetime(&channel)
init(_ channel: inout IO.Event.Channel) {
    unsafe self.base = .init(&channel)
}
```

The compiler emits a `TemporaryPointers` diagnostic because it cannot prove the
pointer outlives the `inout` scope. The pointer IS valid — the `~Escapable`
constraint plus `@_lifetime(&channel)` guarantees the view cannot escape the
`_read`/`_modify` coroutine that keeps the parent exclusively borrowed.

## Files

- `Sources/IO Events/IO.Event.Channel.Shutdown.swift` — `base: UnsafeMutablePointer<IO.Event.Channel>`
- `Sources/IO Stream/IO.Stream.Shutdown.swift` — `stream: UnsafeMutablePointer<IO.Stream>`

## Revalidation test

Replace the `UnsafeMutablePointer` field with a hypothetical safe reference type,
or check whether the compiler stops warning when `~Escapable` + `@_lifetime` is
present. The test is: can the `init` drop the `unsafe` keyword without a
`TemporaryPointers` warning?

```swift
// If this compiles without warning, the workaround can be removed:
@_lifetime(&channel)
init(_ channel: inout IO.Event.Channel) {
    self.base = .init(&channel)  // no `unsafe`
}
```

## When to revalidate

Next major toolchain (Swift 6.4+). Watch for:
- SE proposal for stored `inout` / non-escaping mutable references
- `TemporaryPointers` diagnostic learning to see through `~Escapable` lifetimes
