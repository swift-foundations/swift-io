---
date: 2026-04-13
session_objective: Remove Mutex<Shutdown.Token?> from IO.Event.Selector.Scope to work around CopyToBorrowOptimization miscompilation
packages:
  - swift-io
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: skill_update
    target: memory-safety
    description: "Added [MEM-COPY-001a] Deinit immutability for ~Copyable structs"
  - type: no_action
    description: "[skill] handoff compiler-verified After code — rule implied by general verification discipline; not promoted to new requirement to avoid rule proliferation"
---

# Scope Mutex Removal: deinit Immutability and Workaround vs Fix Distinction

## What Happened

Applied the change described in `HANDOFF-scope-mutex-removal.md`: replaced `Mutex<Shutdown.Token?>` with direct `var Shutdown.Token?` on the `~Copyable` `IO.Event.Selector.Scope` struct. This breaks one of six trigger conditions for the CopyToBorrowOptimization + WMO miscompilation that caused `guard state == .running` to be constant-folded to `true` after shutdown.

The handoff's "After" code did not compile. `_token.take()` in the `deinit` fails with "cannot use mutating member on immutable value: 'self' is immutable." The fix was `guard case .some = _token else { return }` — a read-only pattern match that checks presence without mutation. In `consuming func close()`, `.take()` works because consuming grants ownership (mutable access). In `deinit`, `self` is immutable — you can read fields but not mutate them.

Updated `Research/audit.md` (workaround status from "None" to applied), `Research/actor-state-visibility-structural-fix.md` (status and context update), and memory. Deleted completed handoff file. All 143 tests pass in release mode.

Noted that `IO.Completion.Queue.Scope` still uses the identical `Mutex<Shutdown.Token?>` pattern — not changed in this session (different trigger conditions or not yet confirmed affected).

## What Worked and What Didn't

**Worked**: The handoff document provided exact before/after code, file paths, and verification commands. The change was mechanical — the only creative work was fixing the deinit compilation error.

**Didn't work**: The handoff's "After" code for `deinit` was wrong. The `_token.take()` call assumed mutable access in deinit, which Swift doesn't grant. This is a subtle distinction: `consuming` methods get ownership (can mutate), but `deinit` gets immutable access to fields even though the struct is being destroyed. The handoff was written without compiling the "After" code.

**Confidence**: High on the code change itself. The user correctly identified that the workaround proves symptoms are gone, not the bug — the compiler defect remains in the toolchain.

## Patterns and Root Causes

The deinit immutability issue reveals a gap in the mental model of `~Copyable` lifecycle: `consuming` and `deinit` both destroy the value, but they grant different access levels to fields. `consuming` is like `mutating` + destruction. `deinit` is like `borrowing` + destruction. This asymmetry matters when you need to extract values from Optional fields — `.take()` requires mutation, so it works in `consuming` but not `deinit`.

The `guard case .some = _token` pattern is the idiomatic read-only nil check for `Optional<~Copyable>` in deinit. The token itself gets destroyed when `self` is destroyed (its fields are consumed by the compiler), so you only need to check presence — you don't need to extract the value.

The broader pattern: handoff documents that contain untested "After" code are a recurring source of friction. The handoff was otherwise excellent (clear rationale, exact file paths, verification steps), but the one piece that wasn't compiler-verified was the one that broke.

## Action Items

- [ ] **[skill]** memory-safety: Add guidance on deinit immutability for ~Copyable structs — `consuming` grants mutable access, `deinit` does not; `.take()` works in consuming but fails in deinit; use `guard case .some` for nil checks
- [ ] **[skill]** handoff: Add requirement that "After" code blocks in handoff documents SHOULD be compiler-verified before handoff; flag unverified code explicitly
- [ ] **[package]** swift-io: Investigate whether IO.Completion.Queue.Scope's identical Mutex pattern is also susceptible to the CopyToBorrow trigger chain
