//
//  Toolchain.swift
//  swift-io
//

/// Toolchain capability gate for the catalog §A9 `Tagged` metadata SIGSEGV.
///
/// `Kernel.Event.Driver.init`'s registry is
/// `Dictionary_Primitives.Dictionary<Kernel.Event.ID, Registration>` where
/// `Kernel.Event.ID = Tagged<ISO_9945.Kernel.Event, UInt>` (a real
/// `Tagged_Primitives.Tagged`). The first `registry.insert(...)` forces the
/// full type metadata of the institute `__Dictionary`/`__HashIndexed`/
/// `Hash.Entry`/`Buffer.Linear` engine; on Swift 6.3.x
/// `swift_getTypeByMangledName` returns `TypeLookupError("unknown error")`
/// and the caller dereferences the null metadata at `+0x10` → SIGSEGV.
///
/// This is catalog §A9 (`swift-institute/Research/swift-compiler-bug-catalog.md`,
/// Issues entry `swift-issue-tagged-dictionary-insert-metadata-crash`): the
/// io `Kernel.Event.Driver` registry site (§A9 site 3) re-surfacing after the
/// 2026-05-23 revert of its raw-storage workaround and the ADT-tower reshape
/// onto the `Hash.Indexed`-backed `__Dictionary` engine. Root cause:
/// incomplete `SuppressedAssociatedTypes` codegen on 6.3, fixed by 6.4-dev
/// (the fix travels with the compiler binary, not the runtime). There is no
/// Institute-side code fix — the raw-storage wrapper was reverted on
/// correctness grounds — so the affected suite is skipped on the buggy
/// toolchain and runs normally once the compiler ships the fix.
///
/// The reducer proves the trigger is the Tagged KEY alone (a Copyable `Int`
/// value crashes just as a `~Copyable` value does) and that it fires in both
/// DEBUG and RELEASE.
public enum Toolchain {}

extension Toolchain {
    /// `true` on Swift compilers older than 6.4, where the §A9 `Tagged`
    /// metadata SIGSEGV fires. Used as the predicate for the
    /// `.disabled(if:)` trait on the affected io suite. `.disabled(if:)`
    /// (not `withKnownIssue`) is required: a SIGSEGV kills the test runner
    /// before swift-testing can register a known issue, so only skipping the
    /// body yields a clean run on 6.3.x; the guard auto-recovers on 6.4+.
    public static var hasTaggedMetadataSIGSEGV: Bool {
        #if compiler(<6.4)
        return true
        #else
        return false
        #endif
    }
}
