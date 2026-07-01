# Archived Research Notes

Notes here are kept for historical reference only. No active design
material lives here. **Do not cite these as authoritative**; consult
`../README.md` and `Sources/IO Events/README.md` /
`Sources/IO Completions/README.md` instead.

There are two reasons a note ends up here:

1. **Subsumed-by-foundation** — content fully covered by the algebra
   notes (`../io-algebraic-effects-foundation.md`, `../swift-io-thesis.md`).
2. **Overshot** — note elaborated handler-internal operations or
   speculative design as if it were the public swift-io surface.
   Misleading if read in isolation.

## Index — Subsumed-by-foundation (2026-04-20)

| File | Subsumed by |
|------|-------------|
| `io-event-namespace-typealias-vs-enum.md` | foundation §6.2 — namespace representation orthogonal to theory |
| `io-completions-file-classification.md` | foundation §6.3 — file classification subsumed |
| `polling-tick-isolation-checkisolated.md` | E_IO law-preservation — implementation detail |
| `completion-loop-executor-unification.md` | tactical executor composition; subsumed |
| `executor-conformance-inventory.md` | data, not design |
| `multishot-buffer-groups-reader-writer-impact.md` | Σ_Completion variant |
| `sending-mutex-composition.md` | memory-safety idiom; orthogonal |
| `sendable-heap-ref-lifetime-idiom.md` | memory-safety idiom; orthogonal |

## Index — Overshot (2026-04-20)

These four notes were written in the same session that produced the
`Research/README.md`. They elaborate handler-internal signatures into
prose that reads like a public algebra spec — exactly the anti-pattern
called out in `../README.md` §"Anti-pattern 3". Each has a corrective
banner at its top.

| File | What it overshot |
|------|------------------|
| `io-effect-signature-blocking.md` | The `dispatch` op is internal to `IO.Blocking.Actor`; consumers see only `IO.run.blocking { … }` |
| `io-effect-signature-event.md` | `register`/`wait`/`modify`/`unregister` live inside `IO.Event.Actor`; the L1 witness is `Kernel.Event.Driver` |
| `io-effect-signature-completion.md` | `submit_*` ops live inside `IO.Completion.Actor` and `Kernel.Completion.Driver`; not consumer-facing |
| `io-effect-signature-stream.md` | `IO.Reader`/`IO.Writer` are speculative — the actual public surface is fd-direct via `IO`'s 4 closures |

If the swift-io API later grows a public stream layer or a public per-strategy
signature, *write a fresh note* against the actual code. Do not restore
these.

## Restoration

If any archived note proves to contain material *not* actually
subsumed/overshot, restore via `mv Archived/<file>.md ..` and
add a counter-classification entry to `../io-research-corpus-audit.md`.
