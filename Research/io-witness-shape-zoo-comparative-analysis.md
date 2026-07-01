# IO Witness Shape Zoo: Comparative Analysis

<!--
---
version: 1.0.0
created: 2026-04-17
last_updated: 2026-04-17
status: IN_PROGRESS
tier: 3
scope: cross-package (swift-io, swift-kernel, swift-executors, swift-witnesses)
supersedes: none
supersededBy: none
related:
  - swift-foundations/swift-io/Research/io-witness-design-literature-study.md (v4.0 — Shape B baseline)
  - swift-foundations/swift-io/Research/io-witness-capability-runner-split.md (Shape F proposal)
  - swift-foundations/swift-io/Research/io-witness-borrowing-async-tension.md (language constraint)
  - swift-foundations/swift-io/Research/io-blocking-executor-binding.md (v4.0 — Shape B rationale)
  - swift-foundations/swift-io/Research/perfect-api.md (v3.0 — Tier 0 consumer API)
  - swift-foundations/Research/io-vs-nio-comparative-analysis.md (structural comparison)
  - swift-foundations/Research/nio-inspired-capability-additions.md (capability gaps)
  - swift-foundations/Research/io-driver-witness-composition.md (driver layer)
  - swift-primitives/Experiments/io-witness-shape-f/
  - swift-primitives/Experiments/io-witness-domain-via-map/
  - swift-primitives/Experiments/io-witness-macro-generic-compat/
  - swift-primitives/Experiments/io-witness-generic-error/
  - swift-primitives/Experiments/io-witness-generic-ops/
  - swift-primitives/Experiments/io-witness-domain-generic-substrate/
  - swift-primitives/Experiments/io-witness-tokio-style/
  - swift-primitives/Experiments/io-witness-zio-style/
  - swift-primitives/Experiments/io-witness-eio-style/
  - swift-primitives/Experiments/io-witness-monoio-style/
---
-->

## Abstract

This document presents a PhD-level comparative analysis of ten distinct *witness shapes*
proposed as the core abstraction for `swift-io`, the async I/O capability layer of
Swift Foundations. Each shape is realized as a compilable Swift 6.3 sketch in the
`swift-primitives/Experiments/` directory; each corresponds to a named production
I/O library (Apple swift-nio, Tokio, Eio, ZIO, monoio, …) or to an original design
derived from the prior research trajectory documented in `swift-io/Research/`.

The analysis is scoped as a **Tier 3 systematic comparison** under the Kitchenham
methodology for Systematic Literature Reviews, with a formal semantics framing, a
Cognitive Dimensions evaluation of each shape's usability properties, and an
explicit contextualization of each prior-art library in swift-io's own type system.
The ten shapes are: (F) capability+runner split, (Dvm) domain-via-map composition,
(MG) macro-generic compatibility, (GE) generic-error parameter, (GO) generic-ops
parameter, (DGS) domain-generic substrate, (Tk) tokio-style reader/writer/closer
split, (Z) ZIO-style three-parameter effect monad, (E) Eio-style stdenv scope, and
(M) monoio-style rental pattern.

The intent is **comparative**, not prescriptive. The document catalogues — for each
shape — its formal Swift declaration, its academic pedigree (Brachthäuser's
effects-as-capabilities, Ahman & Bauer's runners calculus, Xie & Leijen's evidence
passing, Schuster et al.'s capability-passing compilation), its compatibility with
swift-io's hard constraints (no protocols at public surface, no existentials,
~Copyable descriptor support, typed throws end-to-end, region-based isolation
preferred over Sendable constraints), its composition properties under
`swift-witnesses` operators, and its Cognitive Dimensions profile along six axes
(visibility, consistency, viscosity, role-expressiveness, error-proneness,
abstraction).

The core finding is that the shapes cluster into three disjoint families under
swift-io's hard constraints: (1) **capability witnesses** (F, Dvm, Tk) which trade
surface breadth for composition clarity and preserve all hard constraints; (2)
**parameterized witnesses** (GE, GO, DGS, Z) which trade naming ergonomics for
specialization flexibility, with generic virality varying from benign (GE — error
only) to severe (GO, DGS — virality through every consumer signature); and
(3) **scope and rental variants** (E, M) which impose caller-side rebinding or
scope closures and — under Swift 6.3 region isolation — suffer compounding
`sending`-tax at every scope boundary. The `@Witness` macro was verified to
propagate generic parameters (against the originally expected refutation in
experiment MG), opening a path for macro-based generation in families (2) that
was previously foreclosed.

Shape F preserves the largest number of hard constraints simultaneously and
composes with every `swift-witnesses` operator (`Recording`, `Scope`, `Values`,
`Sequence`, `Cycle`). Shape Dvm is a non-exclusive complement to F, not an
alternative — it specifies the composition mechanism by which domain witnesses
(Socket.IO, File.IO) are derived from a base IO. Shape GE is compatible with F.
Shape Tk is an orthogonal decomposition axis (per-capability split vs. unified).
Shapes Z, M, and E are structurally eliminated by hard-constraint violations or
compounding syntactic tax; Shapes GO and DGS are structurally redundant with
simpler alternatives.

The analysis does not recommend a single shape. A separate decision document
— to be authored after this corpus of comparative data is complete — will
integrate the findings here with implementation constraints and ship-schedule
considerations to select swift-io's final shape.

## Table of Contents

1. [Context](#1-context)
2. [Research Questions](#2-research-questions)
3. [Methodology](#3-methodology)
4. [Preliminaries](#4-preliminaries)
5. [Per-Variant Analysis](#5-per-variant-analysis)
6. [Cross-Cutting Observations](#6-cross-cutting-observations)
7. [Comparative Matrices](#7-comparative-matrices)
8. [Prior Art: Production I/O Libraries](#8-prior-art-production-io-libraries)
9. [Academic Foundations](#9-academic-foundations)
10. [Decision Framework](#10-decision-framework)
11. [Synthesis](#11-synthesis)
12. [Outcome](#12-outcome)
13. [Appendices](#appendices)

---

## 1. Context

### 1.1 Problem Setting

`swift-io` is the async I/O capability layer of the Swift Foundations monorepo.
It stands beneath a constellation of sibling packages — `swift-sockets`,
`swift-file-system`, a future `swift-networking` — and serves as the single
abstraction through which those packages compose with Swift's structured
concurrency. The canonical architecture document establishes a three-strategy
implementation: **Blocking** (dedicated OS threads per operation), **Events**
(readiness-based reactor over `kqueue`/`epoll`), and **Completions**
(completion-based proactor over `io_uring`). The public API surface must unify
all three strategies under a single type so that a consumer writes

```swift
let io = IO.default()  // or IO.blocking() / IO.events() / IO.completions()
let n = try await io.read(from: fd, into: buf)
```

regardless of which strategy is active beneath.

This design problem has occupied the `swift-io/Research/` corpus for several
months, with the debate converging toward **Shape B** (documented in
[io-witness-design-literature-study.md](../swift-io/Research/io-witness-design-literature-study.md)
v4.0): an `IO` value-type struct declared as `@Witness public struct IO: Sendable`
whose stored closures are the primitive operations (`_read`, `_write`, `_accept`,
`_close`), and each strategy implemented as an internal actor that the witness
captures by reference. The follow-up work in
[io-witness-capability-runner-split.md](../swift-io/Research/io-witness-capability-runner-split.md)
identifies a pollution in Shape B: the `_unownedExecutor` accessor sits on the
capability witness even though it is a runner concern, diluting the capability
axiom that the witness exposes only I/O operations. The proposed remedy —
**Shape F** — splits the capability witness from the runner witness, bundling
the two in a plain `IO.Bound` struct.

Throughout this trajectory, each proposal has been evaluated in isolation or in
narrow pairs (B vs F, B vs G). The present document widens the aperture: ten
shapes — F plus nine alternatives derived from specific production libraries or
academic models — are prototyped as compiling Swift 6.3 sketches, and compared
on a common matrix of dimensions. The data produced by this comparison is the
input for a later decision document.

### 1.2 Prior Research Trajectory

The witness-shape debate in swift-io has a dense paper trail. Cited below are
the documents that establish the design space this analysis operates within,
with their versions and last-updated dates so the reader can place each claim
in the debate's timeline.

| Document | Version | Last updated | Key claim |
|----------|---------|--------------|-----------|
| `io-witness-design-literature-study.md` | 4.0 | 2026-04-14 | Shape B is the correct value-type capability form; cites Brachthäuser 2020, Ahman & Bauer 2020, Xie & Leijen 2021, Schuster et al. 2020 as theoretical ground |
| `io-blocking-executor-binding.md` | 4.0 | 2026-04-14 | Shared-executor pattern (TCA26 precedent) provides zero-hop I/O from consumer actors; mandatory binding via actor isolation, not `Task(executorPreference:)` |
| `io-witness-borrowing-async-tension.md` | 1.0 | 2026-04-13 | `borrowing Kernel.Descriptor` + `async` closure raises a language-level tension; `inout sending` or sync closures with external async bridge are the two resolutions |
| `io-witness-capability-runner-split.md` | 1.0 | 2026-04-17 | Shape F — runner-as-witness, bundled by plain struct — preserves the capability axiom that Shape B diluted; enables `Witness.*` composition operators for runner concerns |
| `perfect-api.md` | 3.0 | 2026-04-08 | Tier 0 consumer API is `IO.run(socket) { reader, writer in ... }`; disambiguates async/sync via language context; no constructors on `Stream`/`Context` |
| `io-vs-nio-comparative-analysis.md` | 1.0 | 2026-04-16 | swift-io's value-type witness, typed throws, and `~Copyable` descriptor are structural wins over NIO's reference-type `Channel` + `any Error` futures |
| `nio-inspired-capability-additions.md` | 1.0 | 2026-04-16 | Specific capability gaps (deadline I/O, vectored I/O, shared-singleton shutdown, test fakes) classified as Adopt/Defer/Reject per contextualization |
| `io-driver-witness-composition.md` | 1.0 | 2026-04-13 | `IO.Driver` — a lower layer witness unifying `Kernel.Event.Source` + `Kernel.Completion` — is orthogonal to the `IO` capability witness concerns this document addresses |

The analysis here is the **natural successor** to
`io-witness-capability-runner-split.md`: the 2026-04-17 zoo experiments were
initiated to widen the option space beyond Shape F alone and obtain a structured
comparison with the shapes production I/O libraries have chosen. The present
document is the Tier 3 write-up of that zoo.

### 1.3 The Zoo — Ten Sketches

The ten experiment sketches — all dated 2026-04-17 and all built with Swift 6.3
release on macOS 26 (arm64) — are:

| ID | Directory | Academic model | Library inspiration | Build time |
|----|-----------|---------------|---------------------|------------|
| F | `io-witness-shape-f` | Brachthäuser capability + Ahman & Bauer runner | N/A (original) | 1.27s |
| Dvm | `io-witness-domain-via-map` | Runner-to-runner transformation | N/A (original) | 1.33s |
| MG | `io-witness-macro-generic-compat` | N/A (tooling verification) | N/A | 90.77s |
| GE | `io-witness-generic-error` | Error-indexed effect monad | Haskell `ExceptT`, Rust `Result` | 0.98s |
| GO | `io-witness-generic-ops` | Parameterized algebra | Scala type classes | 0.67s |
| DGS | `io-witness-domain-generic-substrate` | Functor / higher-kinded types | Haskell `IO r a` | 0.65s |
| Tk | `io-witness-tokio-style` | Per-capability algebraic theory | Tokio `AsyncRead`/`AsyncWrite` | 106.98s |
| Z | `io-witness-zio-style` | Effect monad (E-R-A) | Scala ZIO | 0.35s |
| E | `io-witness-eio-style` | Algebraic effect handler in scope | OCaml Eio | 1.23s |
| M | `io-witness-monoio-style` | Linear types + rental | Rust monoio / glommio | 0.58s |

Each sketch contains:

- `EXPERIMENT.md` — hypothesis, method, result, analysis.
- `Sources/main.swift` — compile demonstration (observable output).
- `Sources/*.swift` — the witness declaration and supporting vocabulary
  (one type per file per [API-IMPL-005]).
- `Package.swift` — pinned to Swift 6.3 with the relevant experimental features.

The sketches are **compile-only** — no runtime behaviour is verified, no
benchmarks are run. The point is structural: does the shape compile, and what
does it force on the consumer at the type level?

The `_index.json` at `swift-primitives/Experiments/_index.json` registers all ten
with one-sentence summaries that this document expands.

### 1.4 Document Scope and Non-Goals

This document is in scope for:

1. **Structural comparison** of the ten shapes on a matrix of ~30 dimensions.
2. **Prior-art mapping**: which production library each shape emulates and
   how faithful the emulation is.
3. **Academic grounding**: which formal model each shape implements.
4. **Hard-constraint compliance**: which shapes pass the six constraints
   enumerated in §2.
5. **Cognitive Dimensions evaluation** per [RES-025].
6. **Formal typing rules** for each shape (§4.3, §5).
7. **Identification of candidate finalists** (those not structurally eliminated)
   with their distinguishing trade-offs.

This document is explicitly **out of scope** for:

1. **Final recommendation** of a single shape. A separate decision document
   will integrate these findings with implementation constraints.
2. **Runtime benchmarks**. All sketches are compile-only; no per-op latency or
   per-op allocation data is collected.
3. **Migration planning**. How swift-io's current Shape B code base migrates
   to a chosen shape is deferred to the decision document.
4. **Changes to `Package.swift`** in any ecosystem package.
5. **Proposals for new Swift Evolution proposals** arising from compiler
   limitations encountered in the sketches (those go to separate
   `swift-pull-request` workflows).

---

## 2. Research Questions

### 2.1 Primary Research Question

**RQ0** — Given the ten candidate witness shapes (F, Dvm, MG, GE, GO, DGS, Tk,
Z, E, M), **which structural dimensions discriminate between them under
swift-io's hard constraints, and how does each shape score on each dimension**,
such that the data suffices to select a shape in a subsequent decision document?

This question is intentionally *structural*, not outcome-focused. It asks what
data a decision document would need, not which shape should win.

### 2.2 Secondary Research Questions

**RQ1** — For each of the six hard constraints (no protocols at public surface,
no existentials, ~Copyable Kernel.Descriptor parameters, typed throws
end-to-end, region-based isolation preferred over Sendable constraints, Swift
6.3 release toolchain compatible), **which shapes satisfy the constraint, which
violate it structurally, and which violate it only under specific sub-designs?**

**RQ2** — How does each shape map onto the formal models of algebraic effects
(Plotkin & Pretnar 2009, Leijen 2017), runners (Ahman & Bauer 2020),
capabilities (Brachthäuser 2020), and evidence passing (Xie & Leijen 2021)?
For shapes that claim multiple models (e.g. F claims both capability and
runner), what is the mapping, and what does the mapping *exclude*?

**RQ3** — For each shape, how does the `@Witness` macro in `swift-witnesses`
interact with the declaration? Which shapes yield a usable macro expansion
(init, `unimplemented()`, method wrappers, `Calls`, `Observe`)? Which shapes
hit the macro's limitations (generic parameter propagation, zero-parameter
closures, ownership annotations in mock synthesis)?

**RQ4** — For the shapes that admit *composition operators*
(`Witness.Recording`, `Witness.Scope`, `Witness.Values`, `Witness.Sequence`,
`Witness.Cycle`), which operators apply, and what does each operator give the
consumer? Composition is a first-order design concern because swift-io's
testing story depends on it.

**RQ5** — What is each shape's *consumer ergonomic profile* — quantified via
the Cognitive Dimensions Framework (Green & Petre 1996) — along the six
dimensions (visibility, consistency, viscosity, role-expressiveness,
error-proneness, abstraction)? Scores are relative across the ten shapes, not
absolute.

**RQ6** — Which shapes are *compatible combinations*? Specifically: is Shape F
orthogonal to Shape Dvm (domain-via-map as composition operator on top of the
capability/runner split)? Is Shape F orthogonal to Shape GE (generic-error
parameter added to the capability witness)? Which pairings are NOT compatible,
and why?

**RQ7** — For the five shapes derived from production libraries (Tk→Tokio,
Z→ZIO, E→Eio, M→monoio, implicit F→NIO-inspired), how faithful is the Swift
translation? Which Swift type system features introduce a gap — and for each
gap, is the gap structural (cannot be closed without language change) or
incidental (the translation could be better)?

**RQ8** — What compile-time and compile-resource cost does each shape impose?
Build times range from 0.35s (Z) to 106.98s (Tk); the longer times indicate
macro expansion cost. Is this cost prohibitive, or amortized by incremental
compilation?

### 2.3 Out-of-Scope Questions

The following questions arise naturally in the course of the analysis but are
**deferred** to other documents, for reasons stated:

**OOS1** — "Which shape should swift-io adopt?" — Out of scope per §1.4. A
later decision document will answer this.

**OOS2** — "What are the runtime performance characteristics of each shape?"
— The zoo experiments are compile-only. Runtime characteristics would require
benchmark suites not yet authored. Schuster et al. 2020 establish that
evidence-passing (the shape-agnostic structure of all ten) is the optimal
compilation strategy at 150× over dynamic handler lookup, but this is a
compile-time property of the underlying structure, not a shape-level property.

**OOS3** — "What is the migration path from current Shape B to each candidate
shape?" — Migration planning belongs in the decision document or in a
migration-specific research document.

**OOS4** — "Should the `@Witness` macro be extended to handle zero-parameter
closures with auto-generated method wrappers?" — This is a `swift-witnesses`
concern. Experiment E flagged the gap; the fix lives in
`swift-witnesses/Sources/Witnesses Macros Implementation/WitnessMacro.swift`.

**OOS5** — "Should swift-io adopt the `swift-effects` algebraic-effects
infrastructure?" — Documented as open in Shape B literature study §"Existing
Infrastructure: swift-effects". The answer is orthogonal to shape selection.

---

## 3. Methodology

This section presents the methodology for the analysis, meeting the
requirements of [RES-023] (SLR per Kitchenham), [RES-024] (formal semantics),
[RES-025] (Cognitive Dimensions), and [RES-026] (citations to primary sources).

### 3.1 Kitchenham-style Systematic Literature Review Protocol

Kitchenham's SLR methodology — formalized in Kitchenham 2004, "Procedures for
Performing Systematic Reviews", and refined in Kitchenham & Charters 2007,
"Guidelines for performing Systematic Literature Reviews in Software
Engineering" — prescribes six stages: (1) research questions (above), (2)
search strategy, (3) inclusion/exclusion criteria, (4) screening, (5) data
extraction, (6) synthesis. Stages 2–6 are documented below.

#### 3.1.1 Search Strategy

**Sources searched**:

- **Swift ecosystem**: the `swift-foundations/Research/` directory, the
  `swift-foundations/swift-io/Research/` directory, the `swift-institute/
  Research/` directory, and the `swift-primitives/Experiments/` directory.
  These together contain the prior art for swift-io's design decisions.
- **Swift Evolution**: SE-0413 (typed throws), SE-0414 (region-based
  isolation), SE-0417 (task executor preference), SE-0430 (`sending`
  parameters), SE-0431 (`@isolated(any)`), SE-0461 (run nonisolated async
  functions on caller's actor by default), SE-0456 (Span), SE-0458 (Strict
  Memory Safety), SE-0392 (custom actor executors).
- **Academic literature**: the ACM Digital Library, arXiv, and the published
  conference proceedings for POPL, ICFP, OOPSLA, ESOP, and PLDI for the years
  2009–2024. Specific queries run: "algebraic effects", "effect handlers",
  "runners", "evidence passing", "capabilities", "linear types", "session
  types", "async await effects", "region-based memory".
- **Production library documentation**: primary sources (library
  documentation, source code) for swift-nio (Apple), Tokio (Tokio Project),
  Boost.Asio (Boost), Netty (Netty Project), Eio (OCaml 5 / Anil Madhavapeddy
  et al.), ZIO (ZIO Project / John De Goes), monoio (ByteDance), glommio
  (Glauber Costa / DataDog), .NET Stream, Rust `std::io`, Go `net` package.
- **Swift compiler source**: `swiftlang/swift` for compiler-version-specific
  behaviour (e.g. `swift-6.3-fix-status.md` in user memory).

**Query terms**:

- *For academic*: `"algebraic effect" AND (handler OR runner OR capability)`;
  `"evidence passing"`; `"capability-passing compilation"`; `"typed throws"`;
  `"linear types" AND I/O`; `"region calculus"` (Tofte & Talpin); `"session
  types" AND I/O`.
- *For production libraries*: `"AsyncRead poll_read"` (Tokio); `"Stdenv.t"`
  (Eio); `"ZIO[R, E, A]"`; `"monoio rental buffer"`; `"NIO Channel pipeline"`.
- *For Swift internals*: `"Sendable @Sendable" site:forums.swift.org`;
  `"sending parameter" site:github.com/swiftlang/swift`; `"~Copyable generic"
  "@Witness macro"`.

**Date range**: academic 2009–2024 (Plotkin & Pretnar 2009 is the earliest
cited source); production library 2017–2024 (NIO dates 2017; monoio dates
2022); Swift ecosystem 2025–2026 (matches the Swift Institute research
corpus).

#### 3.1.2 Inclusion / Exclusion Criteria

**Included**:

- Any work that directly defines or analyzes one of: *algebraic effects*,
  *effect handlers*, *effect runners*, *value-type capabilities*, *evidence
  vectors*, *capability-passing compilation*, *linear types for I/O*,
  *session types for I/O*, *asynchronous effects*, *region-based isolation*.
- Any production I/O library whose public API shape corresponds to one of the
  ten zoo shapes. "Corresponds" is a structural equivalence: the library's
  core type declares the same set of operations in the same algebraic form as
  the shape under test.
- Any Swift Evolution proposal that constrains or enables the zoo shapes at
  the language level.
- Any Swift Institute research document referenced in the `_index.json` of
  `swift-foundations/Research/` or `swift-foundations/swift-io/Research/`.
- Any Swift Institute feedback memory relevant to the shape design (listed in
  the user's `MEMORY.md`).

**Excluded**:

- General Swift tutorials, blog posts, and Stack Overflow answers. These are
  not primary sources.
- Benchmark papers that compare async I/O runtimes without reference to the
  underlying abstraction. Benchmarks are interesting but not what this
  comparative analysis is about.
- Earlier-version drafts of Swift Institute research documents that have been
  explicitly superseded (e.g., the v3.0 version of `io-blocking-executor-
  binding.md` is excluded; the v4.0 is included).
- I/O libraries whose public API shape is *reference-typed* without a
  value-type alternative, because our hard constraint forbids reference-type
  capabilities. These libraries (e.g., Netty, .NET Stream) are included in
  §8 for structural context but their shapes are not included in the zoo.

#### 3.1.3 Screening Process

The set of candidate zoo shapes was bounded at ten by the `_index.json`
listing. The academic and production sources were screened by (a) relevance
to the research questions, (b) direct citation chain from the four seminal
papers (Ahman & Bauer 2020, Brachthäuser 2020, Xie & Leijen 2021, Schuster
et al. 2020), and (c) structural correspondence to at least one zoo shape.

Sources that survived screening: approximately 22 academic papers, 10
production libraries, 9 Swift Evolution proposals, 12 Swift Institute
research documents, 8 user-memory feedback entries. The References section
(§Appendix G) lists all of them.

Sources excluded in screening: general Swift-async tutorials (n ≈ 40, all
excluded); benchmark-only runtime comparisons without shape analysis
(n ≈ 15, all excluded); superseded research-doc drafts (n ≈ 8, excluded
per §1.2 table's "Version" column).

#### 3.1.4 Data Extraction Template

For each zoo shape, the following data are extracted verbatim from the
sketch and EXPERIMENT.md:

1. Shape name and experiment directory.
2. Build status (PASS / FAIL) and build time.
3. The primary type's formal Swift declaration (copied verbatim from the
   sketch's `IO.swift` or analogous file).
4. All closure signatures (copied verbatim).
5. Error type declaration.
6. `~Copyable` parameter annotations.
7. `@Sendable` or `sending` annotations.
8. Sendable conformance of the type itself.
9. Macro usage (`@Witness`, `@CoW`, `@Defunctionalize`, etc.).
10. Lines of code (measured on the `Sources/` directory).
11. Caveats noted in the EXPERIMENT.md Result section.

For each academic source:

1. Author, year, venue, title.
2. Primary claim.
3. Which zoo shape it informs.
4. Relevance to hard constraints.

For each production library:

1. Library name and maintainer.
2. Core type (verbatim declaration from upstream source).
3. Formal correspondence to a zoo shape (if any).
4. Features the zoo shape does not cover (if any).
5. Citation for the claim (URL, commit, file/line if source).

#### 3.1.5 Synthesis Approach

Synthesis is **structural**. For each research question (§2.2), the data
extracted is folded into:

- A comparative table covering all ten shapes on that question's dimension
  (§7).
- A narrative explanation, per shape, of the table entry's rationale (§5).
- Cross-references to the academic source and/or production library that
  establishes the shape's behaviour (§§8, 9).

Claims are cited inline via `[Author Year]` pointing to the References
section. Claims that cannot be verified from primary sources are flagged
with `[UNVERIFIED]` and do not contribute to the synthesis.

### 3.2 Empirical Evaluation via the Zoo

The ten sketches in `swift-primitives/Experiments/io-witness-*/` are
empirical artefacts: they demonstrate that the shape compiles (or not) under
Swift 6.3 release with strict memory safety enabled. Each sketch is minimal
— a single executable that constructs the shape and prints confirmation —
so that the compile outcome discriminates shape-level feasibility from
orthogonal concerns.

Compile outcome is recorded as the Result section of each EXPERIMENT.md.
Each sketch's Result section has been **verified** by re-reading the linked
build log or build output. No sketch is currently in a failed state; all
ten report `Build complete!` with timings documented in the table of §1.3.

The sketches demonstrate *compilation* — they do not demonstrate
*correctness of behaviour*. Behaviour correctness would require unit
tests, which are out of scope per §1.4.

### 3.3 Cognitive Dimensions Framework

Green & Petre's Cognitive Dimensions Framework (Green 1989; Green & Petre
1996; Blackwell et al. 2001) provides a vocabulary for evaluating the
usability of notations — which includes API surfaces, which are notations
for effects. The framework enumerates fourteen dimensions, of which six
are directly relevant to API-facing shape decisions and which the research
process skill [RES-025] explicitly names. Each dimension is defined below
and each zoo shape is scored on it (§5.x.11, §7.3) on a three-point ordinal
scale {low, medium, high} relative to the cohort.

**Visibility and juxtaposability** — the extent to which required parts of
the notation can be identified and placed in proximity. For a witness shape:
"can a reader identify the set of operations the witness supports from its
declaration?" A witness with four explicit closures has higher visibility
than one with a generic operation-set parameter. Across the cohort, Shape F
has the highest visibility (four closures, all named); Shape GO has the
lowest (operation set is opaque until the generic parameter is instantiated).

**Consistency** — the extent to which similar meanings are expressed by
similar syntactic forms, and different meanings by different forms.
Consistency is *internal* to the shape and *external* to the cohort. Shape
Tk (three separate witnesses) is externally consistent with Tokio (different
traits for different capabilities); Shape F (one unified witness) is
internally consistent (four closures all have the same shape modulo
parameters).

**Viscosity** — resistance to local change. For a witness shape: "if one
operation's signature changes, how many sites must be updated?" A witness
with dedicated closures has higher viscosity than a generic one (every
consumer that named `.read(...)` must update). Across the cohort, Shape F
is medium-viscosity; Shape Z's combinators introduce per-call cost that is
viscous to modify.

**Role-expressiveness** — the extent to which the purpose of a component is
clear from its role in the notation. For a witness: "does the name of each
field express the operation's purpose?" Shape F scores high (`_read`,
`_write`, `_close`, `_ready`); Shape DGS scores low because the "substrate"
is opaque.

**Error-proneness** — the extent to which the notation invites mistakes. For
a witness shape: "can a consumer accidentally misuse the shape?" Shape M
(rental) has high error-proneness (forgetting to re-bind the returned buffer
is a compile error *or* a latent correctness bug depending on which
operation is next); Shape F has low error-proneness.

**Abstraction** — the extent to which the notation allows the user to
introduce new abstractions. For a witness shape: "can the consumer build
new witnesses from existing ones?" Shape Dvm explicitly supports this via
`.map`; Shape F supports it via the bundled `IO.Bound` plus `Witness.*`
operators; Shape M does not.

Three other Cognitive Dimensions — *hidden dependencies*, *hard mental
operations*, *premature commitment*, *progressive evaluation*, *provisionality*,
*secondary notation*, *diffuseness*, *closeness of mapping* — are noted where
particularly relevant (§5.x.11) but not scored systematically; they are
subsumed or orthogonal under the six above for the witness shape question.

### 3.4 Formal Type-Theoretic Framing

Section 4.3 defines the formal typing rules for the witness pattern that all
ten shapes instantiate. Section 5 presents the per-shape specializations of
these rules, with particular attention to the rules' interaction with
`~Copyable`, typed throws, and region isolation.

The formal framing is Swift-native — the rules are written in terms of Swift
6.3 type theory (value types, owned parameters, sending parameters, typed
throws) rather than a stylized effect calculus. This choice is deliberate:
the goal is to make the rules verify against the compiler's actual
behaviour, not against an abstract ideal model. Where the compiler's rules
are known (e.g., SE-0413's semantics of typed throws) they are cited; where
they are observed empirically (e.g., the `sending R` region-inheritance
gotcha in `mapError`) the observation is labelled as such.

### 3.5 Threats to Validity

Per Yin 2003's categorization (adapted to API design research):

**Construct validity** — whether the extracted data measure what they claim.

*Threat*: compile success is a weak proxy for shape-level feasibility. A
shape can compile and still be unusable at scale (e.g., viral generics).
*Mitigation*: each sketch's EXPERIMENT.md Result section includes
identified caveats; §§5.x, 6 enumerate these explicitly. Compile success is
treated as *necessary but not sufficient*.

*Threat*: the six Cognitive Dimensions are ordinal, not cardinal. Relative
ranking is meaningful; absolute scores are not.
*Mitigation*: §5.x.11 and §7.3 present scores as ordinal bands {low,
medium, high}; no claim of a 3.7/5 is made.

**Internal validity** — whether the comparisons are fair.

*Threat*: the ten sketches are not all the same size. Shape F has ten
source files (due to the [API-IMPL-005] one-type-per-file refactor); Shape
Z has four. Line counts may be confounded by the refactor.
*Mitigation*: line counts are recorded in §Appendix C but are not a primary
comparator. Structural comparisons (does the shape compile, what is its
generic-parameter count) are dominant.

*Threat*: the author of this analysis was aware of the prior research
trajectory pointing toward Shape F. Selection bias is possible.
*Mitigation*: the document structure prescribes equal treatment per shape
(§5.x has ten subsections with identical sub-template). Verdict (§5.x.12)
is a single paragraph per shape, not a ranking. Final synthesis (§11) does
not pick a winner; the decision is deferred.

**External validity** — whether the comparisons generalize.

*Threat*: the zoo is ten shapes; many plausible shapes are not in the
zoo (e.g., algebraic-effects via `swift-effects`, delimited continuations
via coroutines, protocol-based dispatch which is excluded by hard
constraint 1).
*Mitigation*: the "no protocols" constraint (§2.2 RQ1) is stated upfront;
it excludes some shapes by design. Within the no-protocol design space,
the ten zoo shapes cover the salient academic-model and production-library
families. Additional shapes can be added in future revisions.

**Reliability** — whether the same data and protocol would produce the
same comparisons.

*Threat*: Swift 6.3 release and 6.4-dev nightly differ; regressions have
been observed (see memory `feedback_toolchain_versions.md`). A future
compiler version may report different compile outcomes.
*Mitigation*: §1.3 records the exact toolchain and host (Swift 6.3 release,
macOS 26 arm64). Each shape's EXPERIMENT.md locks in the date and
toolchain.

---

## 4. Preliminaries

This section defines the terms, type-system concepts, and formal frame that
the per-shape analysis (§5) builds on.

### 4.1 Swift 6.3 Concurrency and Isolation Model

The zoo shapes are evaluated under the Swift 6.3 release toolchain. The
relevant concurrency features are:

#### 4.1.1 Sendable

`Sendable` (introduced in Swift 5.5, stabilized in Swift 5.7) is a protocol
indicating that a value of a type can be safely shared across isolation
boundaries. Conformance is either **checked** (synthesized by the compiler
when all stored properties are `Sendable`) or **unchecked** (`@unchecked
Sendable`, which suppresses the compiler's data-race check). Per
[MEM-SAFE-024], `@unchecked Sendable` falls into one of four semantic
categories:

- **A: Synchronized** — type uses an internal mutex, atomic, or lock.
- **B: Ownership transfer** — `~Copyable` type whose move semantics make
  concurrent access impossible.
- **C: Thread-confined** — type is pinned to a single thread; current
  workarounds are pending `~Sendable` (SE-0518).
- **D: Structural workaround** — provably safe but the compiler cannot
  verify (e.g., `@_rawLayout`, non-Sendable generic parameter).

#### 4.1.2 `sending` Parameters and Region Transfer

SE-0430 (`sending` parameter and result values) introduced region-based
isolation. A `sending` parameter is one whose value transfers ownership of
its *region* — a set of references that may alias — to the callee. This
enables non-Sendable values to cross isolation boundaries without requiring
`@unchecked Sendable`. The compiler's region-isolation checker
(`#RegionIsolation` in diagnostics) tracks regions through control flow.

Key semantic points:

- `sending T` on a parameter asserts: "the caller gives up its region to
  the callee; after this call the caller cannot access the value".
- `sending T` on a return: "the callee gives a fresh region to the caller;
  the caller receives a value disconnected from the callee's region".
- `Sendable T` is strictly a superset: any `Sendable` value can be sent;
  values sent across a boundary need not be `Sendable`. See memory
  `feedback_sending_over_sendable_return.md` ("Use `sending R` not
  `R: Sendable` on actor returns; strictly more flexible").

The zoo's region-isolation migration (applied to all ten sketches in the
2026-04-17 refactor) replaced `@Sendable` closure attributes with `sending`
parameters on consumer APIs, dropped `Sendable` conformances where only
closure storage was the concurrency-relevant field, and removed `&
Sendable` from generic constraints where the error type was not required
to cross isolation boundaries.

One known region-isolation pitfall — illustrated in Shape M — is that the
checker is flow-sensitive but not flow-symbolic: `var buf = initial;
for _ in 0..<N { let (returned, n) = op(consume buf); buf = returned }`
fails because the re-bound `buf` is not in a sending region for the next
iteration. This is not a defect of `sending`; it is a current limit of
the checker's precision. Workaround: keep the payload type `Sendable` so
that region isolation is not the only isolation mechanism.

#### 4.1.3 `isolated` Parameters

SE-0392 (custom actor executors) introduced `isolated Actor` parameters.
A function declaring `(isolated A) -> R` is isolated to `A` for its
duration — calls to `A`'s methods are synchronous. Shape F uses this in
its runner witness indirectly: the `_executor` closure returns
`UnownedSerialExecutor` which a consumer actor's `unownedExecutor`
accessor can forward, enabling the shared-executor pattern (TCA26
precedent, documented in `io-blocking-executor-binding.md` v4.0).

Memory `feedback_isolated_param_for_borrowing_noncopyable.md` records
that `isolated Actor` is the preferred mechanism for borrowing
`~Copyable` values across actor boundaries — no closure is needed, unlike
the `withLock` pattern.

#### 4.1.4 `NonisolatedNonsendingByDefault` (Upcoming Feature)

SE-0461 (run nonisolated async functions on caller's actor by default) is
enabled via the `NonisolatedNonsendingByDefault` experimental feature in
Swift 6.3. When enabled, a `nonisolated func foo() async` called from an
actor runs on that actor's executor by default — no hop. This affects
witness shapes indirectly: the wrapper method `io.read(...)` that
forwards to `_read(...)` is a `nonisolated func`, and with SE-0461 its
dispatch profile matches the consumer's isolation.

### 4.2 ~Copyable and Ownership

`~Copyable` types (SE-0390 Noncopyable Structs and Enums, stabilized in
Swift 5.9) have move semantics: their values are neither implicitly nor
explicitly copied. The relevant `~Copyable` type for this analysis is
`Kernel.Descriptor`:

```swift
extension Kernel {
    public struct Descriptor: ~Copyable, Sendable {
        public let raw: Int32
        public init(raw: Int32) { self.raw = raw }
    }
}
```

(verbatim from `swift-primitives/Experiments/io-witness-shape-f/Sources/
Kernel.Descriptor.swift`)

`Kernel.Descriptor` is:

- `~Copyable` — a descriptor cannot be duplicated; ownership is single.
- `Sendable` — synthesized by the compiler (all stored properties are
  Sendable), enabling transfer across isolation boundaries.
- Moved via `consume` (explicit) or by passing through a `consuming`
  parameter.
- Borrowed via `borrowing` parameters for read access without transfer.

For the witness shapes, `Kernel.Descriptor` appears as:

- `borrowing Kernel.Descriptor` — in the closures for `_read`, `_write`,
  `_accept`, `_ready`. Consumer keeps the descriptor after the call.
- `consuming Kernel.Descriptor` — in the closure for `_close`. Consumer
  relinquishes ownership; compile error to use the descriptor after.

A key constraint: **tuples with `~Copyable` elements are not supported in
Swift 6.3**. A closure signature like `async throws -> (Kernel.Descriptor,
Socket.Address)` fails with "tuple with noncopyable element type
'Descriptor' is not supported". This affects Shape Dvm's accept operation
and Shape M's rental return. The workaround is to wrap the result in a
named `~Copyable` struct.

[API-IMPL-005] One Type Per File applies to the sketches: each `.swift`
file in `Sources/` contains exactly one type declaration (or extensions
of a declared type), which is why Shape F has ten source files rather
than one.

### 4.3 The Witness Pattern — Formal Definition

All ten zoo shapes are variations on the **witness pattern**: a value-type
struct whose stored properties are closures. This section gives the formal
definition — drawing on three equivalent theoretical names — and states
the typing rules.

#### 4.3.1 Three Equivalent Names

The witness pattern has three names in the literature, proven equivalent:

**Evidence vector** (Xie & Leijen 2021, "Generalized Evidence Passing for
Effect Handlers", ICFP). An evidence vector is a record — a tuple with
named fields — where each field holds the implementation of one abstract
operation. Xie & Leijen prove this is the optimal compilation strategy
for effect handlers: the evidence is a compile-time-resolved record
passed by value, and each handler call is a direct indirect call through
a field of the record.

**Value-type capability** (Brachthäuser, Schuster, Ostermann 2020,
"Effects as Capabilities: Effect Handlers and Lightweight Effect
Polymorphism", OOPSLA). A capability is an unforgeable, communicable
token of authority. In the effect-handler setting, a capability is a
value parameter that proves the holder may perform the associated
operations. Capabilities are **second-class**: they can be passed as
arguments but cannot escape their introduction scope. The paper's
contribution is showing that first-class effect handlers can be
compiled to second-class value-type capabilities with no loss of
expressiveness.

**Defunctionalized effect handler** (Plotkin & Pretnar 2009, "Handlers
of Algebraic Effects", ESOP; Leijen 2017, "Type Directed Compilation of
Row-Typed Algebraic Effects", POPL). In classical algebraic-effects
syntax, a handler is a function that matches on operations:

```
handler = {
  return x |-> e_r
  op_1(args, k) |-> e_1
  ...
  op_n(args, k) |-> e_n
}
```

Defunctionalization turns each operation clause into a dedicated
function, and bundles the functions as a record. This record is
structurally a witness.

**Schuster et al. 2020** ("Compiling Effect Handlers in
Capability-Passing Style", ICFP) demonstrates that capability-passing —
handlers as value-type records passed explicitly — yields a **150×
speedup** over dynamic handler lookup (searching a handler stack at
effect-performance time). The witness-of-closures shape is thus not
merely a design preference; it is the optimal compilation strategy known
for effect systems.

The three names are not three different ideas. They are three angles on
the same algebraic-structure, proven equivalent by the literature. The
swift-io witness is this structure.

#### 4.3.2 Formal Typing Rules

Let `S` range over witness structs; `s : S` is a witness value. Each
shape declares a set of stored closures `{f_1, ..., f_n}` with signatures
`τ_1, ..., τ_n`. The rules below establish when a witness construction
typechecks.

**Rule W-Struct (witness as value):**

```
S = struct { let f_1: τ_1; ...; let f_n: τ_n }
Γ ⊢ c_1 : τ_1   Γ ⊢ c_2 : τ_2   ...   Γ ⊢ c_n : τ_n
-------------------------------------------------
Γ ⊢ S(f_1: c_1, ..., f_n: c_n) : S
```

A witness is constructed by providing one closure per field at the
correct type. This is the baseline Swift value-type construction rule;
`@Witness` provides the labeled initializer automatically.

**Rule W-Call (witness as capability):**

```
s : S     f_i : τ_i ∈ S
--------------------------
s.f_i : τ_i
```

A stored closure is called by dotting into the witness. The `@Witness`
macro optionally generates a forwarding method `s.f_i(_ args)` whose
body is `_f_i(args)`. The forwarding method preserves all parameter
ownership annotations (`borrowing`, `consuming`) *except* when the
parameter is unlabeled or when the closure has zero parameters (two
known macro limitations, §6.9).

**Rule W-Sendable (witness as transferable):**

```
S = struct Sendable { let f_1: (sending T) async throws(E) -> sending R; ... }
All stored fields are Sendable closures (satisfied by region isolation).
------------------------------------------------------------------------
S : Sendable
```

A witness is `Sendable` when all its stored closures are `Sendable`. In
the region-isolation style, closures need not be annotated `@Sendable`;
what matters is that the witness's stored types can transfer across
isolation boundaries. The 2026-04-17 zoo refactor demonstrates that
`@Sendable` closures are not required: the `@Witness` macro is
"Sendable-agnostic" (§6.1).

**Rule W-Copyable (witness holds Copyable storage):**

```
S is declared without ~Copyable suppression.
Each closure τ_i is Copyable (holds no ~Copyable stored state).
---------------------------------------------------------
S is Copyable.
```

Closure values are `Copyable` even if their captures include `~Copyable`
types (the closure value is a reference-typed block; its payload is
boxed). Therefore all zoo witnesses are Copyable, even when their
closures accept `~Copyable` parameters. This is why witnesses pass
around as values without the ownership ceremony that `~Copyable` types
entail.

**Rule W-Compose (composition operators):**

The `swift-witnesses` library provides composition operators
(`Witness.Recording`, `Witness.Scope`, `Witness.Values`,
`Witness.Sequence`, `Witness.Cycle`) as wrappers. Each wrapper takes a
witness `s : S` and produces a witness `s' : S` whose closures have the
wrapper's additional behaviour spliced in. Formally:

```
compose : (S × Wrapper) → S
compose(s, Recording) = { f_i ← (λ args. do { effects; let r = s.f_i(args); record(r); return r }) }
compose(s, Scope)     = { f_i ← (λ args. do { … teardown on scope exit … ; s.f_i(args) }) }
```

Composition is the key mechanism by which testing, observation, and
lifecycle behaviour are threaded through a witness without modifying its
definition.

#### 4.3.3 Witness Shape as Algebraic Structure

A witness shape is an element of the algebraic structure
**"records of labeled closures"**. The zoo shapes are distinguished by:

1. **Which closures** are declared (i.e., which operations are primitive).
2. **How the closures are parameterized** (error type, operation set,
   substrate).
3. **How multiple witnesses compose** (bundle struct, map, scope, generic
   substrate).
4. **What constraints** are placed on the stored closure types (`@Sendable`,
   `sending`, typed throws, ownership).

All ten shapes share the evidence-vector structure. Their differences are
in dimensions 1–4. This is why shape selection is not a "which is the
right abstraction" debate — all ten are the same abstraction — but a
"which parameterization and composition strategy" debate.

### 4.4 The `@Witness` Macro — What It Generates

The `@Witness` macro (defined in
`swift-foundations/swift-witnesses/Sources/Witnesses Macros
Implementation/WitnessMacro.swift`) expands a struct decorated with
`@Witness` into:

1. **Labeled initializer** — an `init(...)` taking one labeled parameter
   per stored closure, with the underscore-prefixed field names mapped to
   unprefixed parameter labels.
2. **`unimplemented()` static factory** — an instance where every closure
   is `{ _ in fatalError("unimplemented") }`. Useful for test scaffolds.
3. **Method forwarding** — per stored closure with labeled parameters, a
   method of the same name (without the underscore prefix) that forwards
   to the closure. Zero-parameter closures are *not* forwarded (§6.9);
   consumers must write a manual extension.
4. **`Calls` enum** — a case per operation, used by `Witness.Recording`
   to store the call history.
5. **`Observe` wrapper** — a functional composition operator that wraps
   the witness with before/after hooks.

Known limitations:

- **`@Witness(.mock)` disabled for `~Copyable` parameters** — the mock
  generator drops `borrowing`/`consuming` annotations, causing
  "parameter of noncopyable type must specify ownership" errors. See
  `swift-foundations/swift-witnesses/Sources/Witnesses Macros
  Implementation/WitnessMacro.swift:493` and memory `(~none)`.
- **Zero-parameter closures** — no forwarding method is generated
  (Shape E's `Eio.Clock._now` requires a manual `func now()` extension).
- **Generics** — contrary to the originally expected refutation in
  Experiment MG, the macro *does* propagate generic parameters (§5.3).
  Macro expansion runs in the context of the original struct declaration,
  so generic parameters are in scope for synthesized extensions.

### 4.5 Terminology and Notation

Throughout this document:

- **Shape** = a specific witness declaration strategy (F, Dvm, etc.).
- **Witness** = a value-type struct of closures following the pattern of
  §4.3.
- **Capability** = a witness whose stored closures are operations
  (reads, writes, etc.), per Brachthäuser 2020.
- **Runner** = a witness (or actor) whose stored closures are lifecycle
  or scheduling concerns (executor, shutdown), per Ahman & Bauer 2020.
- **Evidence vector** = Xie & Leijen 2021's name for the witness
  structure.
- **Domain witness** = a witness specialized to a domain (Socket.IO,
  File.IO) as opposed to the generic IO.
- **Substrate** = the generic-parameter name for the IO used as the
  underlying engine of a domain witness.
- **Consumer** = code that uses an `IO` value to perform I/O.

Code excerpts are *verbatim* from the experiment sketches unless
otherwise noted. Academic citations use `[Author Year]` inline with the
full reference in §Appendix G. Swift Evolution proposals are cited as
`SE-NNNN`. Swift Institute feedback memories are cited by their
filenames.

---

## 5. Per-Variant Analysis

Ten subsections follow — one per shape. Each subsection contains eleven
numbered sub-points with a fixed template:

1. **Shape summary** — one-paragraph description.
2. **Source citation** — the sketch's EXPERIMENT.md and primary source
   files with line ranges.
3. **Compile outcome** — PASS/FAIL and Build time from EXPERIMENT.md.
4. **Theoretical pedigree** — which academic model the shape implements.
5. **~Copyable compatibility** — how the shape handles
   `Kernel.Descriptor` and other `~Copyable` values.
6. **Region-isolation compatibility** — how the shape handles `sending`
   parameters, region transfers, and any observed region-checker
   interactions.
7. **Typed-throws compatibility** — whether `throws(E)` is preserved
   end-to-end and any closure inference gotchas.
8. **Macro interaction** — does `@Witness` apply, with what limitations.
9. **Consumer ergonomics** — typical call-site patterns, dot-depth,
   explicit annotations required.
10. **Composition properties** — which `Witness.*` operators apply and
    how the shape composes with its sibling shapes.
11. **Cognitive dimensions scoring** — a six-row table (visibility,
    consistency, viscosity, role-expressiveness, error-proneness,
    abstraction) with low/medium/high and rationale.
12. **Verdict** — one-paragraph summary.

### 5.1 Shape F — Capability + Runner Split

#### 5.1.1 Shape Summary

Shape F is the capability/runner split: two separate `@Witness` structs —
`IO` (the pure-operations capability) and `IO.Runner` (the scheduling and
lifecycle runner) — bundled in a plain value-type struct `IO.Bound` that
carries both. No existentials, no protocols, no generic parameters on
either witness. This shape is the primary recommendation of
`io-witness-capability-runner-split.md` (v1.0, 2026-04-17). The zoo
experiment verifies it compiles cleanly with region-isolation
annotations, `~Copyable` parameters, and typed throws.

#### 5.1.2 Source Citation

- `swift-primitives/Experiments/io-witness-shape-f/EXPERIMENT.md`
  lines 1–44 (hypothesis, method, result, analysis).
- `swift-primitives/Experiments/io-witness-shape-f/Sources/IO.swift`
  lines 1–14 (capability witness declaration).
- `swift-primitives/Experiments/io-witness-shape-f/Sources/IO.Runner.swift`
  lines 1–14 (runner witness declaration).
- `swift-primitives/Experiments/io-witness-shape-f/Sources/IO.Bound.swift`
  lines 1–16 (plain-struct bundle).
- `swift-primitives/Experiments/io-witness-shape-f/Sources/main.swift`
  lines 1–25 (compile demonstration).

The capability witness:

```swift
@Witness
public struct IO {
    let _read:  (_ from: borrowing Kernel.Descriptor, _ into: Memory.Buffer.Mutable) async throws(IO.Error) -> Int
    let _write: (_ to:   borrowing Kernel.Descriptor, _ from: Memory.Buffer)          async throws(IO.Error) -> Int
    let _close: (_ descriptor: consuming Kernel.Descriptor) async -> Void
    let _ready: (_ from: borrowing Kernel.Descriptor, _ interest: Kernel.Interest) async throws(IO.Error) -> Void
}
```

The runner witness:

```swift
extension IO {
    @Witness
    public struct Runner {
        let _executor: () -> UnownedSerialExecutor
        let _shutdown: () async -> Void
    }
}
```

The bundle:

```swift
extension IO {
    public struct Bound {
        public let io: IO
        public let runner: IO.Runner
        public init(io: IO, runner: IO.Runner) {
            self.io = io
            self.runner = runner
        }
    }
}
```

#### 5.1.3 Compile Outcome

**PASS**. Build time 1.27s (cold). Single file count: 10 source files
(post [API-IMPL-005] refactor). `public import Witnesses` is required
per the experiment's notes — bare `import Witnesses` fails with "enum
case 'success' is internal and cannot be referenced from an '@inlinable'
function" under `InternalImportsByDefault`. Buffers use Sendable
stand-ins (`Memory.Buffer` with a `count` field) rather than raw
pointers because the `@Witness` macro synthesizes `Sendable` closures
and raw pointers do not conform.

#### 5.1.4 Theoretical Pedigree

Shape F maps cleanly onto **two distinct academic models**:

- **Brachthäuser 2020** (Effects as Capabilities): the `IO` witness IS
  the capability — a value-type, unforgeable, communicable token of the
  authority to perform read/write/close/ready. The runner's separation
  from the capability preserves the capability axiom that the
  capability exposes only operations, not lifecycle.
- **Ahman & Bauer 2020** (Runners in Action): the `IO.Runner` witness
  IS the runner — it carries scheduling (executor) and lifecycle
  (shutdown) evidence. The runner calculus prescribes that a runner
  manages external resources and guarantees linear resource use plus
  finalization; `IO.Runner._shutdown` is the finalization closure, and
  the `consuming Kernel.Descriptor` on `_close` (in the capability
  witness) is the linear-use enforcement.

This dual grounding is the precise reason Shape F is cleaner than
Shape B: Shape B mixed the two roles on a single witness, violating
Brachthäuser's capability axiom. Shape F keeps them disjoint at the
type level.

#### 5.1.5 ~Copyable Compatibility

`Kernel.Descriptor` is `~Copyable` and flows through the witness
closures as:

- `borrowing` in `_read`, `_write`, `_ready` — consumer retains the
  descriptor after the call.
- `consuming` in `_close` — consumer relinquishes the descriptor.

Neither ownership annotation is dropped by the compiler across the
`@Witness` macro expansion. The forwarding methods inherit the
annotations. This is the hard constraint 4 check (§2.2 RQ1) — Shape F
passes.

The tuple-noncopyable limit (§4.2) does not affect Shape F because
none of its closures return tuples with `~Copyable` elements.

#### 5.1.6 Region-Isolation Compatibility

The 2026-04-17 region-isolation migration (reflected in the current
sketch source) produced the following deltas in Shape F:

- **6× `@Sendable` removed from closures**. The closures in `_read`,
  `_write`, `_close`, `_ready`, `_executor`, `_shutdown` are now plain
  closure types. The compiler derives Sendable from stored closure
  types; explicit `@Sendable` is not necessary.
- **3× Sendable conformances dropped**. The `IO` and `IO.Runner`
  witnesses no longer conform to `Sendable`; the consumer transfers
  them via `sending IO.Bound`.
- **Consumer uses `sending IO.Bound`**. The `observe(_:)` function in
  `main.swift` declares its parameter as `sending IO.Bound`, preserving
  the region-isolation pattern.

Shape F's region-isolation compatibility is demonstrated by the
no-regression compile: the 2026-04-17 migration applied in place and
the sketch continues to compile with the `.strictMemorySafety()` flag
enabled.

#### 5.1.7 Typed-Throws Compatibility

Typed throws preserved end-to-end:

- Each capability closure declares `async throws(IO.Error) -> T`.
- `IO.Error` is a nested enum conforming to `Swift.Error, Sendable` with
  three cases: `closed`, `wouldBlock`, `platform(Int32)`.
- The runner closures are non-throwing (`_executor`) or non-throwing
  async (`_shutdown`); no error type is required on them.

The `@Witness`-generated forwarding methods preserve the typed-throws
signatures. Consumers write `try await io.read(from: fd, into: buf)` and
catch `IO.Error` exhaustively, per [API-ERR-001].

#### 5.1.8 Macro Interaction

`@Witness` expands cleanly on both `IO` and `IO.Runner`:

- Labeled initializer: `IO(read: ..., write: ..., close: ..., ready: ...)`
  and `IO.Runner(executor: ..., shutdown: ...)`.
- `unimplemented()` on both: `IO.unimplemented()` and
  `IO.Runner.unimplemented()` (demonstrated in `main.swift` via
  `IO.Bound(io: .unimplemented(), runner: .unimplemented())`).
- Method forwarding on both where closures have labels. Zero-parameter
  closures (none in Shape F's capability; `_executor` in runner) are
  subject to the zero-parameter-method gap (§6.9).

One observed nuance: the `_executor` closure on `IO.Runner` is
zero-parameter and would not get an auto-generated method, following
the same pattern as Shape E. In practice the capability/runner split
research doc addresses this by suggesting a manual extension.

#### 5.1.9 Consumer Ergonomics

Call-site dot depth for a consumer holding `bound : IO.Bound`:

- Capability call: `bound.io.read(from: fd, into: buf)` — two dots.
- Runner call: `bound.runner.executor()` — two dots (three including
  the manual `executor()` wrapper, since the closure is
  zero-parameter).

This is one dot deeper than Shape B (where `io.read(...)` is one dot
from the consumer). The capability/runner split research doc estimates
the ergonomic cost as "measurable but small" (`C3: 7/10` vs Shape B's
`10/10`).

The shared-executor pattern (TCA26) remains single-line:

```swift
actor Server {
    let bound: IO.Bound
    init() throws { self.bound = try IO.Bound.events() }
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        bound.runner.executor()
    }
}
```

This is the key ergonomic check: the consumer's `unownedExecutor`
accessor forwards from the runner's `executor()`. No generic parameter,
no existential.

#### 5.1.10 Composition Properties

Shape F composes with *every* `swift-witnesses` operator:

- **`Witness.Recording`** — both `IO` and `IO.Runner` have generated
  `Calls` enums; recording attaches to each witness independently and
  the results are two separate recordings.
- **`Witness.Scope`** — `IO.Runner._shutdown` is a natural scope-exit
  action; `Witness.Scope(runner: bound.runner).use { ... }` binds the
  shutdown to a structured lifetime.
- **`Witness.Values`** — `values[IO.self] = ...` and
  `values[IO.Runner.self] = ...` are independent typed slots,
  enabling per-witness dependency injection.
- **`Witness.Sequence`** / **`Witness.Cycle`** — apply to both,
  enabling chained or cyclic composition per witness.

This uniformity across operators is the `C4` criterion in the
capability/runner split research: Shape F scores 10/10 against Shape B's
6/10 and Shape G's 7/10.

Shape F is also compatible with Shape Dvm (§5.2): a domain witness
`Socket.IO` can be built via `bound.io.map { io in ... }`, with the
runner flowing through unchanged.

Shape F is compatible with Shape GE (§5.4): the capability witness can
be made generic over `LeafError: Error` — `IO<LeafError>` — with the
runner staying error-agnostic. The bundle becomes
`IO.Bound<LeafError>`. This is orthogonal to F and can be layered on
top; see §7.7.

#### 5.1.11 Cognitive Dimensions Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Visibility | High | Four capability closures + two runner closures, all explicitly named; operations immediately visible at declaration |
| Consistency | High | Both witnesses have the same `@Witness public struct` shape; all capability closures follow the same `async throws(IO.Error) -> T` template |
| Viscosity | Medium | Adding a new capability closure requires updates at the factory, the macro expansion, and all consumer call sites that exercise it; but the type parameter is fixed so unrelated code is unaffected |
| Role-expressiveness | High | Capability vs runner split communicates intent; each closure's name announces its role (`_read`, `_shutdown`) |
| Error-proneness | Low | Typed throws catch classification at compile time; `~Copyable` ownership catches double-close; `sending` catches region mismatches |
| Abstraction | High | Composes with all `Witness.*` operators; bundle struct is infinitely extensible; no protocol needed |

#### 5.1.12 Verdict

Shape F is the structural baseline for this analysis. It satisfies all
six hard constraints (§2.2 RQ1), maps onto two distinct academic models
cleanly, compiles under Swift 6.3 with region isolation, composes with
every `swift-witnesses` operator, and preserves `~Copyable` descriptor
ownership and typed throws end-to-end. The only non-trivial cost is
the two-dot access at consumer sites; the capability/runner split
research doc accepts this cost as "measurable but small".

Shape F is **non-exclusively compatible** with Shapes Dvm, GE, MG. It is
the starting point for any hybrid shape that combines F with one of
these. No shape in the zoo dominates F across all dimensions; shapes
that differ do so by trading one dimension for another (e.g., Tk trades
unified-operation visibility for per-capability substitution
granularity).

### 5.2 Shape Dvm — Domain via `.map`

#### 5.2.1 Shape Summary

Shape Dvm addresses a different question than Shape F: **how are
domain-specific witnesses (`Socket.IO`, `File.IO`) built from a base
`IO`?** Shape Dvm's answer is a `.map` composition — an `extension IO
{ func map<Domain>(_ transform: (IO) -> Domain) -> Domain }` that
captures the generic `IO` in a closure that calls `io.ready` plus a
raw syscall stand-in, returning a domain witness. No SPI into the base
IO's backing actor is required; no protocol is introduced.

#### 5.2.2 Source Citation

- `swift-primitives/Experiments/io-witness-domain-via-map/EXPERIMENT.md`
  lines 1–48 (hypothesis, method, result, caveats).
- `swift-primitives/Experiments/io-witness-domain-via-map/Sources/IO.swift`
  lines 19–26 (the `map` extension).
- `swift-primitives/Experiments/io-witness-domain-via-map/Sources/Socket.IO.swift`
  lines 1–65 (`Socket.IO` witness + factory).

The `.map` extension:

```swift
extension IO {
    public func map<Domain>(_ transform: (IO) -> Domain) -> Domain {
        transform(self)
    }
}
```

The domain factory (excerpt):

```swift
extension Socket.IO {
    public static func make(from io: sending io_witness_domain_via_map.IO) -> sending Socket.IO {
        io.map { io in
            Socket.IO(
                accept: { (listener: borrowing Kernel.Descriptor) async throws(IO.Error) -> (Kernel.Descriptor, Socket.Address) in
                    try await io.ready(from: listener, interest: .read)
                    // ... sync accept syscall ...
                },
                connect: { (fd: borrowing Kernel.Descriptor, to: Socket.Address) async throws(IO.Error) -> Void in
                    // ...
                },
                shutdown: { (fd: borrowing Kernel.Descriptor) throws(IO.Error) -> Void in
                    // ...
                }
            )
        }
    }
}
```

#### 5.2.3 Compile Outcome

**PASS**. Build time 1.33s.

Three caveats from EXPERIMENT.md:

1. Tuples with `~Copyable` elements are unsupported (§4.2). The accept
   result had to fall back to a Copyable `Descriptor` for this sketch;
   a real `Socket.IO` would use a named `~Copyable` struct `Socket.Accepted`.
2. Typed-throws inference from closure literal parameters is fragile.
   Explicit closure-parameter type annotations
   (`{ (listener: borrowing Descriptor) async throws(IO.Error) -> T in ... }`)
   are required; the `_` form fails.
3. Unified error type (`IO.Error` used for both generic and socket
   domain) keeps the sketch simple. A real two-layer error hierarchy
   requires typed-throws-aware catch blocks or further explicit
   annotations.

The caveats are known Swift 6.3 limits; they affect any shape that uses
tuples-with-`~Copyable` or relies on typed-throws inference through
closure literals. They are not specific to Shape Dvm.

#### 5.2.4 Theoretical Pedigree

Shape Dvm implements a **runner-to-runner transformation** in the
Ahman & Bauer 2020 sense: a runner over a specific domain (Socket) is
built from a runner over a broader domain (IO) by exposing only those
operations that make sense in the narrower domain and re-deriving them
via the base runner's operations. Equivalently, in the evidence-passing
view (Xie & Leijen 2021), Shape Dvm re-encodes a wider evidence vector
into a narrower one.

The shape has no specific production-library precedent (no surveyed
library offers exactly this combinator), but it sits in the algebraic
effect algebraic-handlers tradition: effect handlers are naturally
compositional (one handler's operations can be implemented in terms of
another's).

#### 5.2.5 ~Copyable Compatibility

Same as Shape F for the base `IO`. Domain witnesses (e.g. `Socket.IO`)
pass `borrowing Kernel.Descriptor` through their closures. The
tuple-`~Copyable` caveat (§5.2.3) affects one operation (accept) but
can be resolved with a named struct (`Socket.Accepted`) and is not
structural to the shape.

#### 5.2.6 Region-Isolation Compatibility

Region isolation migrates cleanly:

- **Factory**: `make(from io: sending IO) -> sending Socket.IO` —
  the base IO transfers into the factory and the domain IO transfers
  back out. No generic-parameter Sendable constraint.
- **Observer**: `func observe(_ s: sending Socket.IO) { ... }` —
  consumer pattern replaces `Sendable` conformance with region transfer.
- **`.map` itself**: no `sending` annotations on the `transform`
  parameter. The closure's captures inherit the base IO's region.

The zoo migration notes that "no annotations propagate through `.map`
itself" — this is the combinator being passthrough-transparent, which
is the desired property.

#### 5.2.7 Typed-Throws Compatibility

The typed-throws caveat (§5.2.3) is the salient issue: in a closure
literal inside the `.map` call, Swift 6.3's inference cannot derive the
typed-throws signature from the context. Explicit closure-parameter
type annotations are required, inflating the closure literal
verbosity. This is the same gotcha described in
[API-ERR-004] and observed in
`swift-foundations/Research/io-witness-experiment-results.md`.

The error types themselves remain typed throughout (`throws(IO.Error)`
on each closure).

#### 5.2.8 Macro Interaction

`@Witness` applies to both the base `IO` and the domain `Socket.IO`.
Each witness gets its own macro-generated machinery. The `.map`
extension is a hand-written method on the base witness; it is not
touched by the macro.

#### 5.2.9 Consumer Ergonomics

Consumer holds a domain-specific witness directly:

```swift
let sockets = Socket.IO.make(from: io)
_ = try await sockets.accept(on: listener)
```

Dot depth is one (`sockets.accept`). No bundle access. The domain
witness is itself a `@Witness`, so it also composes with `Witness.*`.

The factory function is the verbose piece — writing
`Socket.IO.make(from:)` requires explicit type annotations on the
closures, per the typed-throws gotcha.

#### 5.2.10 Composition Properties

Shape Dvm **is** a composition operator in its own right — it is the
mechanism by which a domain witness is obtained from a base. It is
orthogonal to Shape F: Shape F's `IO.Bound` can be the base, and the
domain factory takes `bound.io` and produces a domain
`Socket.IO.Bound`.

Composition with `Witness.Recording` on the domain witness gives
recording of `accept`, `connect`, `shutdown` — the operations the
domain witness exposes. Composition on the base IO gives recording of
`read`, `write`, `close`, `ready` — the operations the base exposes.

#### 5.2.11 Cognitive Dimensions Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Visibility | High | Each domain witness shows its own operations directly |
| Consistency | High | Same `@Witness` shape for domain and base; factory pattern uniform |
| Viscosity | Medium | Adding a domain operation requires updating only that domain's factory; base is untouched |
| Role-expressiveness | High | The `.map` name reads naturally; `Socket.IO.make(from:)` is self-documenting |
| Error-proneness | Medium | Typed-throws inference gotcha leads to verbose closures (caveat §5.2.3); forgetting the annotation is a compile error, not a runtime error |
| Abstraction | High | Arbitrarily many domain witnesses can be built; no protocol needed |

#### 5.2.12 Verdict

Shape Dvm is the composition mechanism that lets Shape F (or any base
witness shape) scale to multiple domain witnesses. It is **not an
alternative to Shape F**; it is the natural answer to "how are
Socket.IO, File.IO, Pipe.IO derived from the base IO?" The shape is
non-exclusively compatible with all other shapes in the zoo that have
a base IO at all.

Shape DGS (§5.6) is its closest rival in the solution space — but Shape
Dvm dominates DGS because DGS stores projection closures explicitly
where Dvm captures the base in a closure implicitly; the capture is
structurally simpler. The zoo-experiment author's recommendation
("prefer Dvm over DGS") is carried forward here unchanged.

### 5.3 Shape MG — Macro Generic Compatibility

#### 5.3.1 Shape Summary

Shape MG is not a shape per se — it is a **tooling verification**. The
question: does the `@Witness` macro propagate generic parameters from
the struct declaration into the synthesized members (init,
`unimplemented()`, `Calls`, `Observe`)? The original hypothesis was
that the macro does *not* propagate generics — the exploration had
noted that the macro's implementation does not access
`structDecl.genericParameterClause`. If the hypothesis held, all
downstream generic-variant experiments (GE, GO, DGS) would be forced
to be hand-written rather than macro-based.

The zoo experiment **refuted** the hypothesis in the opposite direction
— the macro *does* propagate generic parameters, yielding a usable
`GenericIO<IOError>.unimplemented()`.

#### 5.3.2 Source Citation

- `swift-primitives/Experiments/io-witness-macro-generic-compat/EXPERIMENT.md`
  lines 1–45.
- `swift-primitives/Experiments/io-witness-macro-generic-compat/Sources/IO.swift`
  lines 19–37.

The declaration under test:

```swift
@Witness
public struct IO<LeafError: Error> {
    let _op: () async throws(LeafError) -> Int
}
```

#### 5.3.3 Compile Outcome

**PASS** — in the surprising direction. Build time 90.77s (cold). The
long build time is attributed to macro expansion over a generic
struct; macro-generated code is type-checked once per specialization.

`GenericIO<IOError>.unimplemented()` resolves correctly. The labeled
initializer is synthesized as `GenericIO<IOError>.init(op: () async
throws(IOError) -> Int)`. The forwarding method (if any) is generated
only when closure parameters are labeled (§6.9); the `_op` closure is
zero-parameter, so no auto-generated method.

#### 5.3.4 Theoretical Pedigree

Shape MG is a tooling-level observation about Swift macro expansion,
not an academic model. The observation is: macros expand in the
context of the original struct declaration, so generic parameters that
appear in the struct's header are in scope within the macro's
synthesized extensions, even if the macro's implementation does not
explicitly read the generic-parameter clause.

This is a mechanical property of the Swift macro system (SE-0389
Attached Macros) and worth recording as a stable point for any
generic-variant shape in swift-io.

#### 5.3.5 ~Copyable Compatibility

N/A — the sketch uses only Copyable storage in the `_op` closure. The
macro generic result generalizes: if the closure had `borrowing
Kernel.Descriptor`, the macro would propagate the ownership annotation
along with the generic parameter. (Verified in Shape F and Shape Tk
indirectly, where macro expansion on non-generic structs preserves
ownership annotations.)

#### 5.3.6 Region-Isolation Compatibility

The sketch declares `IO<LeafError: Error>` without `& Sendable` on the
generic constraint. The region-isolation migration notes: "the macro
does not require Sendable on the generic parameter. Fully
region-isolation-friendly with `<LeafError: Error>` only". This is a
significant finding: the macro's synthesized `Calls` enum and
`Observe` wrapper do not demand `Sendable` on the generic parameter,
so the constraint set is minimal.

#### 5.3.7 Typed-Throws Compatibility

The `_op` closure declares `throws(LeafError)` where `LeafError` is
the generic parameter. Typed throws propagate through the macro
expansion. Consumer code writing `try await instance._op()` catches
the specialized `LeafError` type.

#### 5.3.8 Macro Interaction

This is the shape's entire purpose. The macro:

- Propagates generic parameters into the synthesized init, `Calls`,
  `Observe`.
- Does not require the macro implementation to explicitly reference
  the generic-parameter clause (because the synthesized extensions are
  written on the already-generic struct).
- Takes 90.77s to build for this one test, which indicates macro
  expansion is expensive for generic specializations during a cold
  build. Incremental builds are not measured here.

#### 5.3.9 Consumer Ergonomics

Consumer writes `let demo: IO<Sample.Error> = .unimplemented()`.
Specialization at construction; no runtime type dispatch. Same
ergonomics as any generic Swift value type.

#### 5.3.10 Composition Properties

Full `Witness.*` composition applies to the specialization
`IO<IOError>` — `Recording`, `Observe`, `Scope` operate on a specific
specialization. Composition across specializations (e.g., "observe all
`IO<E>` for any `E`") requires a protocol-based abstraction that the
constraint forbids.

#### 5.3.11 Cognitive Dimensions Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Visibility | High | Single closure; declaration is trivial |
| Consistency | High | Same `@Witness` shape as non-generic variants |
| Viscosity | Low | Changing the generic parameter's constraint is a one-line edit |
| Role-expressiveness | High | `LeafError` name announces its role |
| Error-proneness | Low | Typed throws caught at compile time |
| Abstraction | High | Macro-based specialization removes the boilerplate barrier |

#### 5.3.12 Verdict

Shape MG is a **tooling verification**, not a design choice. Its
finding — that the `@Witness` macro does propagate generic parameters
— is essential context for Shape GE (generic error), Shape GO (generic
ops), and Shape DGS (generic substrate). These shapes could in
principle all be macro-based rather than hand-written, collapsing the
hand-written vs macro-based decision.

The 90.77s cold build time is a signal: macro expansion over generic
structs is expensive; if swift-io adopts a generic variant
(Shape F + GE, say), the macro cost should be factored into CI time
budgets. Incremental builds amortize this, but fresh builds do not.

### 5.4 Shape GE — Generic Error

#### 5.4.1 Shape Summary

Shape GE is a hand-written `IO<LeafError: Error>` with `throws(LeafError)`
on each capability closure, plus a `mapError(_:)` extension that
produces a new `IO<NewError>` by wrapping each closure with a
do-catch+transform. The hand-writing is deliberate — it shows the raw
shape without the macro sugar and makes the mapError semantics
visible.

#### 5.4.2 Source Citation

- `swift-primitives/Experiments/io-witness-generic-error/EXPERIMENT.md`
  lines 1–43.
- `swift-primitives/Experiments/io-witness-generic-error/Sources/IO.swift`
  lines 1–54 (generic struct + mapError).

The declaration:

```swift
public struct IO<LeafError: Error> {
    public let _read:  (_ from: borrowing Kernel.Descriptor, _ into: Memory.Buffer.Mutable) async throws(LeafError) -> Int
    public let _write: (_ to:   borrowing Kernel.Descriptor, _ from: Memory.Buffer)         async throws(LeafError) -> Int
    public let _close: (_ descriptor: consuming Kernel.Descriptor) async -> Void
    // labeled init...
}
```

The `mapError` extension:

```swift
extension IO {
    public func mapError<NewError: Swift.Error>(
        _ transform: @escaping (LeafError) -> NewError
    ) -> IO<NewError> {
        IO<NewError>(
            read: { (fd, buf) async throws(NewError) in
                do throws(LeafError) {
                    return try await self._read(fd, buf)
                } catch {
                    throw transform(error)
                }
            },
            // ... write / close identically ...
        )
    }
}
```

#### 5.4.3 Compile Outcome

**PASS**. Build time 0.98s.

Given Shape MG's finding that the macro handles generics, this same
shape could also be written as `@Witness public struct IO<LeafError:
Error>`. The hand-written form remains the reference.

#### 5.4.4 Theoretical Pedigree

Shape GE parameterizes the evidence vector by its error type. In the
evidence-passing view (Xie & Leijen 2021), this is a family of
evidence vectors indexed by `E`. In the capability-passing view
(Brachthäuser 2020), this is a family of capabilities where the error
type is part of the capability's signature.

The `mapError` operation is a **natural transformation** in category-
theoretic terms: it is a uniform way to transform the error type of
each operation in the vector, preserving the composition structure.
Haskell's `ExceptT` monad transformer has the same operation; Rust's
`Result::map_err` is the same pattern at a different altitude.

#### 5.4.5 ~Copyable Compatibility

`borrowing Kernel.Descriptor` flows through each closure as expected.
The `mapError` implementation wraps the closures in new closures that
retain the ownership annotations. Empirically verified in the sketch.

#### 5.4.6 Region-Isolation Compatibility

The shape compiles with `<LeafError: Error>` alone (no `& Sendable`).
The witness type itself is not `Sendable` — consumers transfer via
`sending` at factory and observer boundaries.

One observed limitation: `mapError` *cannot return* `sending
IO<NewError>`. The stored closures carry the source IO's region;
wrapping them in new closures that reference `self` cannot produce a
fresh region. This is a compile-error scenario when the caller wants
to send the mapped IO across an isolation boundary. Workaround: if the
mapped IO must be sent, the factory (not `mapError`) should construct
it from scratch with the target's region.

This limitation is a specific instance of the flow-sensitive region-
checker's inability to re-rooted a closure into a disconnected region
on wrap. It affects Shape GE but not Shape F (which has no `mapError`
analogue).

#### 5.4.7 Typed-Throws Compatibility

Typed throws preserved through the generic parameter. The `mapError`
closures require explicit `throws(NewError) in` and the inner `do
throws(LeafError) { ... } catch { throw transform(error) }` pattern.
This is the same typed-throws verbosity pattern as Shape Z's
combinators (§5.8); cleaner than inference would give but necessary
for the compiler to accept the cross-error transformation.

#### 5.4.8 Macro Interaction

Hand-written; macro not applied in this sketch. Per Shape MG's finding,
`@Witness` would apply successfully. The macro's `Observe` wrapper
would need to be specialized per `LeafError` — a cost the consumer
pays at observation construction.

#### 5.4.9 Consumer Ergonomics

Consumer specifies the error at construction:

```swift
let baseIO = IO<IO<Never>.Error>(/* ... */)
let socketIO: IO<Socket.Error> = baseIO.mapError { Socket.Error.io($0) }
```

The generic parameter is visible at every `IO<E>` spelling. Mitigation:
domain packages can export `typealias Sockets.IO = IO<Sockets.Error>`
(per Shape GO's observation in §5.5.9), which hides the generic at
the consumer surface.

#### 5.4.10 Composition Properties

Shape GE is compatible with Shape F: a generic `IO<E>` becomes the
capability half of `IO.Bound<E>`. The runner remains error-agnostic.

Shape GE is compatible with Shape Dvm: a domain witness can be built
from a specific `IO<E>` via `.map` — the specific `E` is propagated
through to the domain witness's closures.

Shape GE is not compatible with Shape Tk in a simple form: the split
witnesses would each carry a generic parameter, inflating call sites.
A hybrid that keeps the split but parameterizes each split witness
uniformly is possible but verbose.

#### 5.4.11 Cognitive Dimensions Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Visibility | Medium | Error type is visible at every `IO<E>` spelling; operations remain visible |
| Consistency | High | Same witness pattern, just with a generic parameter |
| Viscosity | Medium | Changing the leaf error cascades to every `IO<E>` site; `mapError` absorbs some of this |
| Role-expressiveness | High | `LeafError` name announces role |
| Error-proneness | Medium | Typed-throws inference gotcha in `mapError` closures; explicit annotations required |
| Abstraction | High | `mapError` is a first-class combinator enabling domain-specific error hierarchies |

#### 5.4.12 Verdict

Shape GE is the error-parameterization extension of the base witness
shape. It is compatible with Shape F, Shape Dvm, and (with some cost)
Shape Tk. The `mapError` combinator is a genuine addition that Shape F
alone does not provide. The ergonomic cost is moderate: the generic
parameter is viral through explicit specialization sites, partially
mitigated by domain typealiases.

For swift-io, the question Shape GE raises is "should the core IO
witness carry a generic error parameter?" The answer depends on how
granularly swift-io wants its error domains to be: a single `IO.Error`
for the whole capability is simpler; `IO<Socket.Error>` plus
`IO<File.Error>` plus `IO<Pipe.Error>` enables domain-precise catch
blocks. The decision document will weigh this trade-off.

### 5.5 Shape GO — Generic Ops

#### 5.5.1 Shape Summary

Shape GO generalizes differently than Shape GE: instead of
parameterizing the error type, it parameterizes the **entire operation
set**. `IO<Ops>` carries a single stored property `ops: Ops` where
`Ops` is a domain-specific record of closures (`Socket.Ops`,
`File.Ops`). The IO struct becomes an envelope; the operations live in
the `Ops` record.

#### 5.5.2 Source Citation

- `swift-primitives/Experiments/io-witness-generic-ops/EXPERIMENT.md`
  lines 1–46.
- `swift-primitives/Experiments/io-witness-generic-ops/Sources/IO.swift`
  lines 1–11 (minimal envelope).
- `swift-primitives/Experiments/io-witness-generic-ops/Sources/Socket.Ops.swift`
  lines 1–24 (socket operation record).
- `swift-primitives/Experiments/io-witness-generic-ops/Sources/File.Ops.swift`
  lines 1–24 (file operation record).

The envelope:

```swift
public struct IO<Ops> {
    public let ops: Ops
    public init(ops: Ops) {
        self.ops = ops
    }
}
```

Socket ops:

```swift
extension Socket {
    public struct Ops {
        public let _accept:  (borrowing Kernel.Descriptor) async throws(IO<Socket.Ops>.Error) -> Kernel.Descriptor
        public let _connect: (borrowing Kernel.Descriptor, UInt32) async throws(IO<Socket.Ops>.Error) -> Void
        public let _read:    (borrowing Kernel.Descriptor, Memory.Buffer.Mutable) async throws(IO<Socket.Ops>.Error) -> Int
        public let _write:   (borrowing Kernel.Descriptor, Memory.Buffer)         async throws(IO<Socket.Ops>.Error) -> Int
        public let _close:   (consuming Kernel.Descriptor) async -> Void
        // init...
    }
}
```

#### 5.5.3 Compile Outcome

**PASS**. Build time 0.67s.

#### 5.5.4 Theoretical Pedigree

Shape GO is a **parameterized algebra** in the universal-algebra
sense: `IO<Ops>` is the container, `Ops` is the operation signature.
Scala's typeclass pattern is similar — a trait `IO[Ops]` can be
specialized by any `Ops` struct. Without protocols, Swift cannot
express "any Ops that provides `accept`" — the generic parameter is
opaque.

The closest theoretical analogue is **higher-kinded types** (Haskell's
`* -> *`), but Swift lacks kinds, so `Ops` is a type, not a type
constructor.

#### 5.5.5 ~Copyable Compatibility

Each `Ops` record's closures declare `borrowing Kernel.Descriptor`
etc. The envelope IO does not directly interact with `~Copyable`
values; its `ops` field is Copyable (it's a struct of closures).

#### 5.5.6 Region-Isolation Compatibility

The region-isolation migration preserves the shape one-for-one:
`sending IO<SocketOps>` replaces `IO<SocketOps>: Sendable` wherever
the latter appeared in consumer APIs. The virality profile is
unchanged — every consumer signature that names `IO<SocketOps>` also
says `sending`.

#### 5.5.7 Typed-Throws Compatibility

The error type is `IO<Socket.Ops>.Error` — nested on the specific
specialization. Each closure's error is typed. Catch blocks catch the
specialization-specific error.

#### 5.5.8 Macro Interaction

Hand-written in the sketch. The macro could in principle apply to
each `Ops` record (per Shape MG's finding), but the envelope `IO<Ops>`
is trivial enough that the macro adds little. The consumer ergonomics
issue dominates.

#### 5.5.9 Consumer Ergonomics

**Virality at every consumer signature**:

```swift
func runEchoServer(listener: borrowing Kernel.Descriptor, io: sending IO<Socket.Ops>) async throws(IO<Socket.Ops>.Error)
func compactFile(fd: borrowing Kernel.Descriptor, io: sending IO<File.Ops>) async throws(IO<File.Ops>.Error)
func runBoth(sockets: sending IO<Socket.Ops>, files: sending IO<File.Ops>)
```

Every consumer explicitly names `IO<X>`. There is no protocol-free
opaque spelling that says "some IO with any ops" — that would require
a protocol.

Mitigation: domain packages export typealiases
(`typealias Sockets.IO = IO<Socket.Ops>`). This hides the generic at
the consumer surface but does not eliminate it from the underlying
type. Three domain packages → three typealiases; five domains → five.
Each alias documents one specialization. Documentation footprint
grows.

Dot depth: `io.ops._accept(listener)` — three dots, with the `ops`
layer visible to the consumer. (The sketch's consumer writes
`io.ops._accept` directly.)

#### 5.5.10 Composition Properties

Composition: the `Ops` records are not witnesses themselves (no
`@Witness` in the sketch), so `Witness.Recording` does not apply. The
envelope `IO<Ops>` is trivial and composition-less.

Alternative: make `Ops` records `@Witness` themselves. This restores
composition for each domain; the envelope becomes `IO<Socket.Ops>`
where `Socket.Ops` is a `@Witness`. This pattern is structurally
identical to Shape Dvm (§5.2) — at which point Shape GO is absorbed
into Shape Dvm.

#### 5.5.11 Cognitive Dimensions Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Visibility | Low | Operations hidden behind `io.ops._op`; viewing the shape requires looking at the `Ops` record |
| Consistency | Medium | All `Ops` records follow the same pattern, but the envelope adds a layer |
| Viscosity | High | Changing the envelope vs `Ops` convention cascades through every consumer |
| Role-expressiveness | Medium | `ops` is a generic name; specific `Ops` types announce roles |
| Error-proneness | Medium | Generic parameter virality leads to mismatched specialization errors |
| Abstraction | Medium | Specialization via `Ops` is flexible but viral |

#### 5.5.12 Verdict

Shape GO compiles and achieves specialization. The ergonomic cost of
generic virality is substantial — every consumer signature names the
specific `IO<X>`. The shape is **structurally redundant with Shape
Dvm**: if `Socket.Ops` were itself a `@Witness`, the shape collapses to
Shape Dvm. The envelope `IO<Ops>` adds no operations, only a wrapper.

Shape GO is ruled out as a primary shape for swift-io, but serves as
a boundary case that justifies Shape Dvm's closure-capture pattern over
the store-ops-explicitly alternative.

### 5.6 Shape DGS — Domain Generic Substrate

#### 5.6.1 Shape Summary

Shape DGS is Shape GO's close cousin: instead of parameterizing on an
operation set, it parameterizes on the IO substrate itself.
`Socket.IO<Substrate>` stores the substrate and exposes projections
that call substrate operations. Without a protocol, the substrate is
opaque: the domain witness must also store explicit projection closures
to expose the substrate's operations.

#### 5.6.2 Source Citation

- `swift-primitives/Experiments/io-witness-domain-generic-substrate/EXPERIMENT.md`
  lines 1–42.
- `swift-primitives/Experiments/io-witness-domain-generic-substrate/Sources/Socket.IO.swift`
  lines 1–49.

The declaration:

```swift
extension Socket {
    public struct IO<Substrate> {
        public let substrate: Substrate
        public let _accept: (borrowing Substrate, borrowing Kernel.Descriptor) async throws(IO.Error) -> Kernel.Descriptor
        // init...
    }
}
```

Specialization to `IO`:

```swift
extension Socket.IO where Substrate == io_witness_domain_generic_substrate.IO {
    public static func on(_ io: sending IO) -> sending Socket.IO<IO> {
        // ...
        accept: { substrate, listener in
            try await substrate._ready(listener, .read)
            return Kernel.Descriptor(raw: -1) // simulated
        }
    }
}
```

#### 5.6.3 Compile Outcome

**PASS** compile-wise. Build time 0.65s.

EXPERIMENT.md's status is "CONFIRMED, but REDUNDANT with
io-witness-domain-via-map".

#### 5.6.4 Theoretical Pedigree

Shape DGS is a **higher-kinded-types emulation**: in Haskell, one would
write `data SocketIO s a = ...` where `s` is the substrate and `a` is
the result. Without kinds, Swift requires an explicit projection table.

#### 5.6.5 ~Copyable Compatibility

Same as Shape Dvm for `borrowing Kernel.Descriptor`.

#### 5.6.6 Region-Isolation Compatibility

Region-isolation migration does not change the conclusion: `sending`
added at init/factory boundaries, shape still redundant with Dvm.

#### 5.6.7 Typed-Throws Compatibility

Same as Shape Dvm.

#### 5.6.8 Macro Interaction

Same as Shape GO.

#### 5.6.9 Consumer Ergonomics

Consumer writes `sockets.accept(on: listener)` after constructing
`Socket.IO<IO>`. The generic parameter is visible at specialization
sites. Strictly worse than Shape Dvm where the generic parameter is
eliminated.

#### 5.6.10 Composition Properties

Same composition surface as Shape Dvm, but with the extra generic
layer making it harder to compose.

#### 5.6.11 Cognitive Dimensions Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Visibility | Low | Substrate is opaque; projection closures are explicit |
| Consistency | Medium | Resembles Shape Dvm but with generic virality |
| Viscosity | High | Generic parameter cascades through |
| Role-expressiveness | Low | "Substrate" is a generic placeholder |
| Error-proneness | Medium | Generic mismatch errors at specialization |
| Abstraction | Medium | Substrate abstraction is leaky (projection closures required) |

#### 5.6.12 Verdict

Shape DGS is **redundant with Shape Dvm** and strictly inferior on
every ergonomic dimension. The zoo-experiment author's recommendation
("prefer `io-witness-domain-via-map` over `io-witness-domain-generic-
substrate`") is carried forward here unchanged. DGS is ruled out on
structural-redundancy grounds.

### 5.7 Shape Tk — Tokio-style Reader/Writer/Closer Split

#### 5.7.1 Shape Summary

Shape Tk emulates Tokio's `AsyncRead` / `AsyncWrite` trait split: each
capability is a separate `@Witness` struct, and consumers that need
multiple capabilities either thread multiple parameters or consume a
plain bundle struct `IO.Duplex`. The split enables fine-grained test
fakes (a mock Reader without a Writer) at the cost of consumer-side
parameter threading.

#### 5.7.2 Source Citation

- `swift-primitives/Experiments/io-witness-tokio-style/EXPERIMENT.md`
  lines 1–43.
- `swift-primitives/Experiments/io-witness-tokio-style/Sources/IO.Reader.swift`
  lines 1–15.
- `swift-primitives/Experiments/io-witness-tokio-style/Sources/IO.Writer.swift`
  lines 1–15.
- `swift-primitives/Experiments/io-witness-tokio-style/Sources/IO.Closer.swift`
  lines 1–15.
- `swift-primitives/Experiments/io-witness-tokio-style/Sources/IO.Duplex.swift`
  lines 1–21.

Three separate witnesses:

```swift
extension IO {
    @Witness
    public struct Reader {
        let _read: (_ from: borrowing Kernel.Descriptor, _ into: Memory.Buffer.Mutable) async throws(IO.Error) -> Int
    }

    @Witness
    public struct Writer {
        let _write: (_ to: borrowing Kernel.Descriptor, _ from: Memory.Buffer) async throws(IO.Error) -> Int
    }

    @Witness
    public struct Closer {
        let _close: (_ fd: consuming Kernel.Descriptor) async -> Void
    }
}
```

Plain bundle:

```swift
extension IO {
    public struct Duplex {
        public let reader: IO.Reader
        public let writer: IO.Writer
        public let closer: IO.Closer
    }
}
```

#### 5.7.3 Compile Outcome

**PASS**. Build time 106.98s (cold) — significantly longer than Shape
F due to three macro expansions in one package. Incremental builds
presumably faster.

#### 5.7.4 Theoretical Pedigree

Shape Tk is **per-capability algebraic theory** (Plotkin & Pretnar
2009): each operation is its own effect signature, each handled
independently. This is how classical algebraic effects are typically
presented in papers — one signature per operation. Composite signatures
are formed by union (bundle).

Tokio's real-world shape matches this: `tokio::io::AsyncRead` is a
trait with `poll_read`; `tokio::io::AsyncWrite` is a separate trait
with `poll_write`, `poll_flush`, `poll_shutdown`. Tokio's `TcpStream`
implements both.

#### 5.7.5 ~Copyable Compatibility

Each witness handles `~Copyable` parameters cleanly:

- `Reader._read` and `Writer._write`: `borrowing Kernel.Descriptor`.
- `Closer._close`: `consuming Kernel.Descriptor`.

Ownership annotations flow through the `@Witness` macro as with Shape
F.

#### 5.7.6 Region-Isolation Compatibility

The zoo migration notes: "three `sending` consumer parameters replace
three `@Sendable` function attributes — one-for-one with strictly more
flexibility. Split form incurs zero Sendable-tax inside macro
expansion."

This is a clean win for the split form under region isolation: three
independent `sending` boundaries are explicit and fine-grained; the
consumer sees exactly which witness is being transferred.

#### 5.7.7 Typed-Throws Compatibility

`Reader._read` and `Writer._write` declare `throws(IO.Error)`.
`Closer._close` is non-throwing. Typed throws preserved through macro.

#### 5.7.8 Macro Interaction

Three macro expansions → three `unimplemented()` static factories,
three `Calls` enums, three `Observe` wrappers. Each witness is
independent.

Cost: build time 106.98s vs Shape F's 1.27s. The build cost scales
approximately linearly with the number of `@Witness` declarations.
For a large codebase with many split witnesses, this is non-trivial.

#### 5.7.9 Consumer Ergonomics

Single-capability consumer (clean):

```swift
static func drain(fd: borrowing Kernel.Descriptor, reader: sending IO.Reader, buffer: Memory.Buffer.Mutable) async throws(IO.Error) {
    _ = try await reader.read(from: fd, into: buffer)
}
```

Multi-capability consumer (verbose or bundle):

```swift
static func proxy(fd: borrowing Kernel.Descriptor, ops: sending IO.Duplex, ...) async throws(IO.Error) {
    _ = try await ops.reader.read(from: fd, into: buf)
    _ = try await ops.writer.write(to: fd, from: payload)
}
```

Bundle access is two dots (`ops.reader.read`) — same as Shape F's
bundle access. Threading three parameters directly is the alternative.

In swift-sockets' actual call patterns (accept → read → write → close
are invariably used together on a connection), the bundle is the
common case. The split is paying extra surface area for a
substitution granularity that is rarely exercised independently.

#### 5.7.10 Composition Properties

Per-witness composition is fine-grained:

- `Witness.Recording` on `Reader` alone records only reads.
- `Witness.Scope` binds one witness to a lifetime; others are
  unaffected.
- `Witness.Values` has independent slots per witness.

Shape Tk is compatible with Shape Dvm: a domain witness could split
into `Socket.Reader`, `Socket.Writer`, etc., each built from the base
IO via `.map`.

Shape Tk + Shape F: the runner witness sits beside the three
capability witnesses; `IO.Bound` becomes `IO(reader, writer, closer,
runner)`.

#### 5.7.11 Cognitive Dimensions Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Visibility | High | Each witness declares its one operation transparently |
| Consistency | High | All three witnesses have identical structural form |
| Viscosity | Medium | Adding a new operation requires new witness; splitting existing shape requires consumer refactor |
| Role-expressiveness | High | Reader/Writer/Closer names are self-explanatory |
| Error-proneness | Low | Typed throws; `~Copyable`; bundle access well-typed |
| Abstraction | High | Per-capability substitution; composition per witness |

#### 5.7.12 Verdict

Shape Tk achieves fine-grained per-capability substitution. The
ergonomic cost is parameter threading at multi-capability call sites,
mitigated by the bundle struct. The build-time cost (106.98s cold) is
significant but amortized by incremental builds.

For swift-io, Shape Tk's question is: **does the bundled use case
dominate?** If most consumers need all three (read + write + close),
the split adds surface area for rare independent substitution. If test
granularity (mock Reader alone) is highly valued, the split pays off.
The decision document will weigh this trade-off.

### 5.8 Shape Z — ZIO-style Effect Monad

#### 5.8.1 Shape Summary

Shape Z emulates Scala ZIO's `ZIO[R, E, A]` three-parameter effect
monad in Swift: `IO<R, E: Error, A>` stores a single `run: (R) async
throws(E) -> sending A` closure, with combinators `map`, `flatMap`,
`mapError`, `provide`. The `R` parameter is the environment (capability
bundle); `E` is the error; `A` is the result.

#### 5.8.2 Source Citation

- `swift-primitives/Experiments/io-witness-zio-style/EXPERIMENT.md`
  lines 1–48.
- `swift-primitives/Experiments/io-witness-zio-style/Sources/IO.swift`
  lines 1–58.

The type:

```swift
public struct IO<R, E: Error, A> {
    public let run: (R) async throws(E) -> sending A
    public init(_ run: @escaping (R) async throws(E) -> sending A) { self.run = run }
}
```

The four combinators:

```swift
extension IO {
    public func map<B>(_ f: @escaping (sending A) -> sending B) -> IO<R, E, B>
    public func flatMap<B>(_ f: @escaping (sending A) -> IO<R, E, B>) -> IO<R, E, B>
    public func mapError<F: Error>(_ f: @escaping (E) -> F) -> IO<R, F, A>
    public func provide(_ env: sending R) -> IO<Void, E, A>
}
```

#### 5.8.3 Compile Outcome

**PASS**. Build time 0.35s.

EXPERIMENT.md notes: "VERDICT REVISED under region isolation: `sending
R` on `provide(_:)` plus `sending A` on run-closure return ELIMINATE the
`R: Sendable` requirement — `~Copyable` descriptors could now serve as
R. Shape is more viable than originally documented."

#### 5.8.4 Theoretical Pedigree

Shape Z is **ZIO's R-E-A effect monad**. The relevant literature:

- De Goes, J. "ZIO: Type-Safe, Composable Asynchronous and Concurrent
  Programming for Scala." (the ZIO library's canonical
  description).
- Wadler, P. 1992, "The Essence of Functional Programming", POPL. The
  monadic-computation tradition.
- Ahman, D. 2017, "Handling Fibred Algebraic Effects", POPL. The
  algebraic-effects view of monadic computation.

Unlike the effect-handler tradition (where the handler is separated
from the computation and the effect is performed without dispatch at
the call site), ZIO's style keeps the computation explicit: each
`IO<R, E, A>` is a *description* of a computation that will be run
given an `R`. `map`/`flatMap` construct the description tree; `run`
executes it.

#### 5.8.5 ~Copyable Compatibility

The original ZIO literature study suggested the `R` parameter would
need to be `Sendable`, precluding `~Copyable` descriptors. The
region-isolation migration changes this: with `sending R` on
`provide(_:)`, non-Sendable (including `~Copyable`) `R` values can be
transferred into the computation. The result `A` is also `sending` so
`~Copyable` results are viable too.

This revision makes Shape Z more viable than originally assessed —
though the combinators still have ergonomic costs.

#### 5.8.6 Region-Isolation Compatibility

Extensive use of `sending`:

- `sending A` on the run closure's return.
- `sending R` on `provide(_:)`.
- `sending A` on `map`/`flatMap` closure's param and return.

The compounding `sending` annotations are the ZIO's style's price for
region-safety.

#### 5.8.7 Typed-Throws Compatibility

**Every combinator closure required explicit typed-throws annotation**.
`{ r in try await ... }` fails with "invalid conversion of thrown
error type 'any Error' to 'E'" because Swift does not infer the
closure's typed-throws from the enclosing generic context. All four
combinators use the form `{ (r: R) async throws(E) -> B in ... }`.

This is a significant ergonomic cost for a shape intended to be
combinator-heavy. Users would pay it on every combinator chain — the
whole point of ZIO-style is chainable combinators, and Swift's current
typed-throws inference makes the chain verbose.

#### 5.8.8 Macro Interaction

Shape Z is not a witness in the per-operation sense; it stores a
single `run` closure. `@Witness` could in principle apply, but the
expansion would generate a single `run(_ env: R)` forwarder — which
is already the natural method. The macro adds little.

#### 5.8.9 Consumer Ergonomics

Consumer builds a computation as a pipeline:

```swift
let computation = Socket.read(count: 4096)
    .map { $0 * 2 }
    .flatMap { bytes in IO<..., String> { _ in "read \(bytes) bytes" } }
    .mapError { _ in Socket.Error.closed }
```

Each `.map`, `.flatMap`, `.mapError` allocates a closure. Chains
build up per-call allocation — potentially measurable vs direct
witness-of-closures.

No executor-binding story: ZIO's "runtime" concept does not map to
Swift's `UnownedSerialExecutor`. There is no `io.unownedExecutor`
spelling. This rules out the shared-executor pattern that Shape F
enables.

#### 5.8.10 Composition Properties

Shape Z's native composition is the monadic combinator set
(`map`/`flatMap`/`mapError`/`provide`). These are orthogonal to
`Witness.*` operators: a ZIO-style `IO<R, E, A>` is not a witness in
the per-operation sense, so `Witness.Recording` doesn't apply.

Shape Z could wrap a witness-based IO (e.g., use Shape F's `IO` as the
`R` parameter of a ZIO `IO<IO.Bound, IO.Error, Int>`). This is a
**layering** — ZIO as a higher-level composition on top of a witness
capability — rather than a replacement.

#### 5.8.11 Cognitive Dimensions Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Visibility | Low | Single `run` closure obscures the operations; must infer from `R` |
| Consistency | Medium | All four combinators follow the monadic-combinator template |
| Viscosity | High | Combinator chain requires rewriting for additions |
| Role-expressiveness | Medium | `R`, `E`, `A` are conventional monad names but not Swift-native |
| Error-proneness | High | Typed-throws closure annotations required on every combinator; missing one is a compile error |
| Abstraction | Medium | Monadic combinators are expressive but orthogonal to Swift's async/await |

#### 5.8.12 Verdict

Shape Z is a monadic-combinator alternative to the witness-pattern.
Under region isolation, the original showstopper (`R: Sendable`
precluding `~Copyable` descriptors) is eliminated, but two significant
costs remain:

1. **Typed-throws verbosity in combinators** — every combinator
   closure needs an explicit `throws(E)` annotation.
2. **No executor binding** — no `io.unownedExecutor` equivalent; the
   shared-executor pattern is not supported.

Shape Z is structurally eliminated for swift-io's core capability by
the executor-binding concern alone (hard constraint 4 in criterion C4
of the capability/runner split research). It remains viable as a
higher-layer composition on top of a witness capability — but that is
a separate library, not the core IO.

### 5.9 Shape E — Eio-style Stdenv with Scope

#### 5.9.1 Shape Summary

Shape E emulates OCaml Eio's `Stdenv.t` pattern: a nested bundle of
sub-capabilities (`Eio.Net`, `Eio.File`, `Eio.Clock`), entered via a
scope function `Eio.with(stdenv:_:)` that invokes the caller's body
with the bundle. The scope pattern mirrors OCaml's `Eio_main.run`.

#### 5.9.2 Source Citation

- `swift-primitives/Experiments/io-witness-eio-style/EXPERIMENT.md`
  lines 1–43.
- `swift-primitives/Experiments/io-witness-eio-style/Sources/Eio.Stdenv.swift`
  lines 1–17 (bundle).
- `swift-primitives/Experiments/io-witness-eio-style/Sources/Eio.with.swift`
  lines 1–15 (scope function).
- `swift-primitives/Experiments/io-witness-eio-style/Sources/Eio.Clock.swift`
  lines 1–23 (one sub-capability + manual `now()` extension).

Three sub-capabilities:

```swift
@Witness public struct Eio.Net: Sendable {
    let _connect: @Sendable (_ host: String, _ port: UInt16) async throws(IO.Error) -> Kernel.Descriptor
}
@Witness public struct Eio.File: Sendable {
    let _open: @Sendable (_ path: String) async throws(IO.Error) -> Kernel.Descriptor
}
@Witness public struct Eio.Clock: Sendable {
    let _now: @Sendable () -> UInt64
}
```

The bundle:

```swift
extension Eio {
    public struct Stdenv: Sendable {
        public let net: Eio.Net
        public let file: Eio.File
        public let clock: Eio.Clock
    }
}
```

The scope:

```swift
extension Eio {
    public static func with<R, E: Swift.Error>(
        stdenv env: Stdenv,
        _ body: (Stdenv) async throws(E) -> sending R
    ) async throws(E) -> sending R {
        try await body(env)
    }
}
```

#### 5.9.3 Compile Outcome

**PASS**. Build time 1.23s.

EXPERIMENT.md caveat: **The `ClockCapability` with a zero-parameter
closure (`_now: () -> UInt64`) did NOT get an auto-generated `now()`
method from the `@Witness` macro** — the macro requires at least one
labeled parameter to synthesize a labeled forwarding method. A manual
`extension Eio.Clock { public func now() -> UInt64 { _now() } }` is
required. This replicates swift-io's `_unownedExecutor` →
`unownedExecutor` manual extension pattern.

#### 5.9.4 Theoretical Pedigree

Shape E is an **algebraic effect handler in scope** (Plotkin & Pretnar
2009; Sivaramakrishnan et al. 2021, "Retrofitting Effect Handlers onto
OCaml"). OCaml 5's effect handlers implement this scope-based model:
handlers are installed via `match ... with | effect op k -> ...`
patterns that scope a set of operations. Eio adapts this for I/O
specifically.

The scope form is **second-class capability passing**: the capability
cannot escape the `body` closure's lifetime. This is exactly
Brachthäuser 2020's value-type-capability model, in a scope-based
presentation.

#### 5.9.5 ~Copyable Compatibility

The sub-capabilities do not use `~Copyable` in the sketch. In a real
translation, they would — at which point the bundle's `Sendable`
conformance becomes harder to justify (but region-isolation `sending`
would be the remedy).

#### 5.9.6 Region-Isolation Compatibility

The scope form pays a **compounding `sending`-tax**. The zoo
migration notes:

- `sending R` on `body`'s return and on `with`'s return.
- Every nested scope call inherits the tax.

This is the key cost of the scope form: a scope function that returns
a generic result must declare `sending R` — and so must every scope
function that calls it, up the call chain. The tax compounds.

Compared to value-type capability passing (Shape F), where the
capability is just a value that moves around, the scope tax is
significant.

#### 5.9.7 Typed-Throws Compatibility

The `with` function declares `throws(E) -> sending R`. Inside the
body, the consumer catches `IO.Error` per capability.

#### 5.9.8 Macro Interaction

Three `@Witness` structs → three macro expansions. The zero-parameter
`_now` closure does not get a forwarding method, requiring a manual
extension. This is the same macro limitation as swift-io's current
`_unownedExecutor` accessor.

#### 5.9.9 Consumer Ergonomics

Consumer enters scope:

```swift
let result = try await Eio.with(stdenv: env) { env throws(IO.Error) in
    let t0 = env.clock.now()
    _ = t0
    // Real code: env.net.connect(host: "example.com", port: 443)
    //            env.file.open(path: "/tmp/data")
}
```

Dot depth: `env.clock.now()` — two dots inside the scope.

The scope form is natural for a CLI program's `main` entry point
(mirroring `Eio_main.run`). It is awkward for long-lived servers where
the capability must be carried by actors that receive requests over
time: actors must either be spawned inside the scope or receive `env`
as a stored property, at which point the scope buys nothing beyond
Shape F's `IO.Bound`.

#### 5.9.10 Composition Properties

Each sub-capability composes with `Witness.*` operators independently.
The bundle itself is a plain struct, not a witness; it doesn't get
composition.

Shape E could layer on top of Shape F: a `Stdenv` made of
`IO.Bound<Net>`, `IO.Bound<File>`, `IO.Bound<Clock>`. The scope
function becomes sugar over passing the bundle.

#### 5.9.11 Cognitive Dimensions Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Visibility | High | Each sub-capability declares its operations |
| Consistency | High | All sub-capabilities have same `@Witness` shape |
| Viscosity | Medium | Adding a sub-capability requires new witness + Stdenv field |
| Role-expressiveness | High | Net/File/Clock names announce roles |
| Error-proneness | Low | Scope ensures capability cannot escape |
| Abstraction | Medium | Scope sugar; subsumed by value-type capability |

#### 5.9.12 Verdict

Shape E compiles, but its central feature (the scope function) adds
compounding `sending` tax that accumulates up the call chain. The zoo
migration notes: "scope form pays compounding `sending`-tax,
reinforces preference for free value-type capability passing over
scope closures."

The scope form is **subsumed by Shape F**: an `IO.Bound` stored on an
actor, or passed via `sending`, achieves the same lifetime-bounded
access without the scope function.

Shape E is structurally eliminated for swift-io's primary surface;
it remains a pattern for specific use cases (CLI `main` entry points)
but not for the library's core capability.

### 5.10 Shape M — monoio-style Rental

#### 5.10.1 Shape Summary

Shape M emulates monoio's rental-buffer pattern for io_uring: the
witness closure takes `consuming Buffer` and returns `(Buffer, Int)`.
Callers re-bind `buf = returnedBuf` on every iteration. The ownership
semantics mirror monoio's actual API shape.

#### 5.10.2 Source Citation

- `swift-primitives/Experiments/io-witness-monoio-style/EXPERIMENT.md`
  lines 1–48.
- `swift-primitives/Experiments/io-witness-monoio-style/Sources/IO.swift`
  lines 1–37.
- `swift-primitives/Experiments/io-witness-monoio-style/Sources/main.swift`
  lines 26–39 (the re-bind loop).

The witness:

```swift
public struct IO {
    public let _read:  (borrowing Kernel.Descriptor, consuming Memory.Buffer) async throws(Error) -> (Memory.Buffer, Int)
    public let _write: (borrowing Kernel.Descriptor, consuming Memory.Buffer) async throws(Error) -> (Memory.Buffer, Int)
    // init...
}
```

The re-bind loop (verbatim):

```swift
func readLoop(io: IO, fd: borrowing Kernel.Descriptor, iterations: Int) async throws(IO.Error) -> Int {
    var buf = Memory.Buffer(capacity: 4096)
    var total = 0
    for _ in 0..<iterations {
        let (returnedBuf, n) = try await io.read(from: fd, into: consume buf)
        buf = returnedBuf   // <-- re-bind every iteration
        total &+= n
    }
    return total
}
```

#### 5.10.3 Compile Outcome

**PASS**. Build time 0.58s.

EXPERIMENT.md notes: "this sketch uses a Sendable `Buffer` struct
rather than `~Copyable` Buffer because the `(Buffer, Int)` tuple would
not be representable with `~Copyable Buffer` (same tuple-noncopyable
limit encountered in `io-witness-domain-via-map`)."

Attempt to use pure-`sending` Buffer without Sendable **FAILED** at
loop re-bind: "`#SendingRisksDataRace` — flow-sensitive region
tracking through var rebind is beyond the current sending-checker".
With `Memory.Buffer: Sendable`, both `consuming` and Sendable live
peacefully — the language checks ownership via `consuming`, and
isolation via Sendable. The conclusion:

> `consuming` (intra-domain ownership) and `sending` (inter-domain
> region transfer) are COMPLEMENTARY, not redundant. Rental shape
> needs `consuming` + Sendable buffer payload; pure `sending` rentals
> only work without rebind loops.

#### 5.10.4 Theoretical Pedigree

Shape M is **linear types for I/O** (Wadler 1990, "Linear Types Can
Change the World!"; Bernardy et al. 2018, "Linear Haskell"). The
buffer is a linear value: it must be consumed exactly once by the
read call, and re-emerges in the return. Rust's move semantics are
the same pattern at a different altitude.

monoio's motivation is io_uring's buffer-ownership contract: the
kernel holds the buffer pointer from SQE submission to CQE
consumption. Returning the buffer in the result signals "the kernel
is done; here's your buffer back". This is correct-by-construction.

#### 5.10.5 ~Copyable Compatibility

Compromised by the tuple-noncopyable limit. The sketch uses a
Copyable `Memory.Buffer` because `(~Copyable, Int)` tuples are not
supported in Swift 6.3. A real implementation would need a named
`~Copyable` struct `Memory.Buffer.Returned { buffer: Buffer; count:
Int }`.

The `consuming` annotation on the closure parameter is preserved. The
ownership is enforced: the caller's `buf` is invalidated after
`consume buf` until the re-bind.

#### 5.10.6 Region-Isolation Compatibility

As noted, pure `sending` Buffer **fails** at rebind — the compiler
cannot prove the re-bound `buf` is in a fresh region for the next
iteration. Workaround: Sendable buffer payload. This means
region-isolation is not sufficient alone; ownership plus Sendable are
both required.

This is the key cross-cutting observation about `consuming` vs
`sending`: they are **complementary**, not alternatives. `consuming`
enforces single-owner flow at the type level; `sending` enforces
region-transfer at the isolation boundary. Shape M needs both.

#### 5.10.7 Typed-Throws Compatibility

`throws(IO.Error)` on each closure; typed throws preserved.

#### 5.10.8 Macro Interaction

Hand-written (no `@Witness` in the sketch). The macro would
propagate but adds little for a two-closure witness.

#### 5.10.9 Consumer Ergonomics

The re-bind loop is the ergonomic cost. Every read call requires
`let (returnedBuf, n) = try await io.read(...); buf = returnedBuf`.
In a tight loop this is two extra lines per iteration vs the borrow
style (`try await io.read(fd, into: buf)` alone).

For one-shot reads the cost is small; for streaming reads it is
significant.

Swift-io's current approach (borrow `Memory.Buffer` with "stable
address until `try await` returns" contract) achieves equivalent
safety via the proactor's cancellation handshake, without the
re-bind. See
`swift-foundations/swift-io/Research/io-proactor-buffer-ownership.md`.

#### 5.10.10 Composition Properties

Shape M's rental pattern does not compose naturally with
`Witness.Recording` (the tuple return complicates the recording
signature) or with `Witness.Scope` (the buffer's lifetime is
explicitly single-call, not scope-bounded).

The shape is **incompatible** with Shape F's unified operation
witness: `_read`'s return differs.

#### 5.10.11 Cognitive Dimensions Scoring

| Dimension | Score | Rationale |
|-----------|-------|-----------|
| Visibility | Medium | Operations declared but return shape is unusual |
| Consistency | Low | Tuple-return differs from other shapes |
| Viscosity | High | Every consumer loop must re-bind |
| Role-expressiveness | Medium | "Rental" concept requires explanation |
| Error-proneness | High | Forgetting to re-bind is an ownership error; re-binding the wrong buffer is a latent bug |
| Abstraction | Low | Rental is hard to generalize |

#### 5.10.12 Verdict

Shape M is **pedantically correct** at the type level but
ergonomically hostile. swift-io's approach (borrow + cancellation
handshake) achieves equivalent safety with better ergonomics. The
zoo-experiment author's conclusion ("rental is rejected on
ergonomic grounds") is carried forward.

Shape M is ruled out as a primary shape for swift-io; its role in the
analysis is as a boundary case demonstrating that `consuming` and
`sending` are complementary mechanisms and that Swift 6.3's region
checker has a flow-sensitive limitation at rebind loops.

---

## 6. Cross-Cutting Observations

This section synthesizes observations that apply across multiple shapes.
Each observation has a descriptive heading, an evidence paragraph citing
specific shapes that exhibit it, and an implication paragraph stating
what the observation means for the decision document.

### 6.1 The `@Witness` Macro Is Sendable-Agnostic

**Evidence**. The 2026-04-17 region-isolation migration removed
`@Sendable` from closures in Shapes F, Tk, Dvm, MG, GE, GO, DGS.
Compilation succeeded without adding any replacement annotation. The
macro's synthesized `init`, `unimplemented()`, forwarding methods,
`Calls` enum, and `Observe` wrapper all work without requiring the
closures to be `@Sendable`. Experiment MG additionally confirmed that
the macro does not require `Sendable` on the generic parameter:
`<LeafError: Error>` alone suffices.

**Implication**. Shapes that use `@Witness` inherit a clean region-
isolation story without `@Sendable` ceremony. The closures' Sendable
status is determined by their captures; region transfer at consumer
boundaries is the `sending`-based mechanism. For any shape chosen,
the macro will not require `Sendable` constraints on type parameters
or on stored closures; the only `Sendable` needed is on the witness
type itself when consumers need it.

### 6.2 Region-Isolation Migration Findings (per-variant `sending`/`@Sendable` deltas)

**Evidence**. The migration applied to all ten shapes produced the
following deltas (summarized from each EXPERIMENT.md):

| Shape | `@Sendable` closures removed | Sendable conformances dropped | `sending` boundaries added | Notes |
|-------|------------------------------|-------------------------------|----------------------------|-------|
| F | 6 | 3 | 1 (`observe`) | Clean migration |
| Dvm | N/A (all closures hand-written) | 1 | 2 (factory, observer) | `.map` is passthrough |
| MG | 0 | 0 | 0 | `& Sendable` removed from generic |
| GE | N/A | N/A | Various | `mapError` cannot return `sending` |
| GO | N/A | N/A | Various | One-for-one replacement |
| DGS | N/A | N/A | Various | Unchanged redundancy verdict |
| Tk | 3 (Reader/Writer/Closer) | 3 | 3 consumer parameters | Cleanest split |
| Z | N/A | 1 (R constraint) | `sending R`, `sending A` | Eliminated R: Sendable |
| E | N/A | N/A | Compounding | Scope form pays tax at each boundary |
| M | 0 (ownership-based already) | N/A (buffer stays Sendable) | FAILED at rebind | Needs both `consuming` and Sendable |

**Implication**. The migration is straightforward for Shapes F, Dvm,
MG, Tk, and even for GE and GO (with caveats noted). Shape E pays a
compounding tax; Shape M requires both `consuming` *and* Sendable.
Shape Z becomes more viable *after* migration (eliminates `R:
Sendable`) but does not overcome the no-executor-binding blocker.

### 6.3 Virality of Generic Parameters

**Evidence**. Shapes GE, GO, DGS, and Z introduce type parameters.
Virality profiles:

- **GE (error)**: viral through `IO<E>` spellings; mitigation is
  domain typealiases.
- **GO (ops)**: virulent; every consumer signature names `IO<X.Ops>`.
- **DGS (substrate)**: virulent plus extra projection closures.
- **Z (R, E, A)**: three-parameter virality; every call site names
  all three unless combinators close parameters.

Shape F, Dvm, MG (post-specialization), Tk, E, M are non-generic at
the public surface (Dvm and Tk use generics only in the `.map` type
parameter or the split witnesses' operations are concrete).

**Implication**. Generic virality is a first-order concern for
consumer ergonomics. A shape that introduces one generic parameter
requires every consumer to name it (or hide it via typealias). Three
parameters (Z) amplify this effect. Shape F's lack of generic
parameters is a deliberate ergonomic benefit.

### 6.4 Tuples of `~Copyable` Are Unsupported (Practical Implications)

**Evidence**. Shapes Dvm and M both hit this limit. Dvm's accept
operation wants to return `(Descriptor, PeerAddress)`; it fell back to
Copyable `Descriptor`. M's read operation wants to return `(Buffer,
Int)`; it fell back to Copyable `Buffer`.

**Implication**. Any shape that wants multi-value returns from
operations on `~Copyable` values must wrap them in named structs
(`Socket.Accepted`, `Memory.Buffer.Returned`). This is manageable —
named structs are one line each — but it is a real limitation of
Swift 6.3 that affects shape design. Shapes F, Tk, and GE avoid this
because their operations return single scalar values.

### 6.5 Typed-Throws Inference Fragility in Closure Literals

**Evidence**. Shapes Dvm, Z exhibit this. In a closure literal
inside a `.map` call or a `flatMap` chain, the compiler cannot infer
the typed-throws signature from the enclosing generic context.
Explicit `{ (arg: T) async throws(E) -> R in ... }` annotations are
required. Without them, Swift widens to `any Error`.

**Implication**. Shapes that rely on combinator chains (Shape Z
significantly, Shape Dvm modestly) inflate their call sites with
annotations. Workarounds are possible at the expense of verbosity.
This is the same phenomenon documented in [API-ERR-004] for rethrows
closures; the closure literal's environment is not enough for the
compiler to infer typed throws.

### 6.6 Complementarity of `consuming` and `sending`

**Evidence**. Shape M's migration attempt demonstrated: pure `sending
Buffer` (without Sendable) fails at `var buf = initial; for _ in ...
{ let (ret, _) = op(consume buf); buf = ret }` — the rebound `buf` is
not in a sending region for the next iteration. With `Buffer:
Sendable`, the ownership checker (via `consuming`) and the isolation
checker (via `sending`/Sendable) work together.

**Implication**. `consuming` and `sending` are complementary, not
alternatives. Shapes that use both (F for `_close`, GE for `_close`,
Tk for `Closer._close`, M for buffers) get both guarantees. The
region checker has a flow-sensitive limitation at rebind loops that
`consuming` alone cannot compensate for. This is a documented Swift
6.3 limit; it does not eliminate any shape but informs how rental
patterns must be layered.

### 6.7 Scope-Tax of `sending R` Mirroring

**Evidence**. Shape E's `with(stdenv:_:)` function declares `body:
(Stdenv) async throws(E) -> sending R`. To propagate the region
through, the outer function itself must declare `throws(E) -> sending
R`. Calls to `with` that themselves need to return their result to a
caller must also carry `sending R`. The tax compounds up the call
chain.

**Implication**. Scope functions are attractive for reasoning about
lifetimes (the capability cannot escape), but they pay a tax at every
nesting level. Value-type capability passing (Shape F's `IO.Bound`) is
a plain struct that moves around without per-nesting tax. For
swift-io's likely use pattern (actors hold `IO.Bound` as stored
properties for the actor's lifetime), the scope tax is a disadvantage.

### 6.8 The `mapError` Region-Inheritance Problem

**Evidence**. Shape GE's `mapError` produces `IO<NewError>` by
wrapping the original closures. The stored closures reference `self`,
so the new closures inherit `self`'s region. The compiler cannot
produce a fresh region for the new IO. Attempting `mapError(_:) ->
sending IO<NewError>` fails.

**Implication**. Any shape that transforms witness values by wrapping
(Shape GE, Shape Dvm's inverse operations, Shape Z's combinators) has
this limitation. The transformed value is in the source's region. If
the consumer wants to transfer the transformed value across an
isolation boundary, the transform must be done at the factory (with a
fresh region) rather than after construction. This is a subtle but
real pattern for consumer code.

### 6.9 Zero-Parameter `@Witness` Closures Don't Auto-Generate Methods

**Evidence**. Shape E's `Eio.Clock._now: () -> UInt64` does not get a
synthesized `now()` method. Shape F's `IO.Runner._executor: () ->
UnownedSerialExecutor` would encounter the same gap. swift-io's
existing `_unownedExecutor` has a hand-written `var unownedExecutor`
accessor. Each closure with zero labeled parameters requires a manual
extension.

**Implication**. Shapes with zero-parameter closures must budget for
manual extensions. This affects Shape F (for the runner's `_executor`
and `_shutdown`), Shape E (for `Eio.Clock._now`), and any future shape
with zero-parameter closures. The fix lives in the `@Witness` macro
implementation, which is `swift-witnesses`'s concern.

### 6.10 Build-Time Costs of Macro Expansion

**Evidence**. Build times ranged from 0.35s (Shape Z, no macro) to
106.98s (Shape Tk, three macros). Shape MG's generic struct with one
macro expansion took 90.77s. Macro-less shapes (Z, M, GE, GO, DGS)
consistently built in under a second.

**Implication**. Macro expansion is the dominant build-time cost. A
shape with N independent `@Witness` structs scales roughly linearly.
For swift-io's CI budget, three-to-four macro expansions are
manageable; more than ten would be problematic. This cost is amortized
by incremental builds but is relevant for fresh-checkout builds.

---

## 7. Comparative Matrices

This section aggregates the per-variant data (§5) into cross-cutting
tables. Each table covers all ten shapes on a specific dimension.

### 7.1 Capability Coverage

What each shape's primary witness expresses (primitive operations):

| Shape | Read | Write | Close | Ready | Accept | Connect | Shutdown | Executor | Open | Now | Map |
|-------|------|-------|-------|-------|--------|---------|----------|----------|------|-----|-----|
| F | ✓ | ✓ | ✓ | ✓ | via Dvm | via Dvm | Runner | Runner | — | — | — |
| Dvm | ✓ | ✓ | ✓ | ✓ | Domain | Domain | — | — | — | — | ✓ |
| MG | 1 generic closure | — | — | — | — | — | — | — | — | — | — |
| GE | ✓ | ✓ | ✓ | — | — | — | — | — | — | — | mapError |
| GO | ops.read | ops.write | ops.close | — | ops.accept | ops.connect | — | — | — | — | — |
| DGS | via subst | via subst | — | via subst | Explicit | — | — | — | — | — | — |
| Tk | Reader | Writer | Closer | — | — | — | — | — | — | — | — |
| Z | via R env | via R env | via R env | — | — | — | — | — | — | — | map/flatMap |
| E | — | — | — | — | — | Net._connect | — | — | File._open | Clock._now | — |
| M | rental | rental | — | — | — | — | — | — | — | — | — |

Notation: ✓ = direct primitive; — = not expressed; "Domain" = built by
Dvm-style construction; "Runner" = on a separate runner witness;
"rental" = consume-and-return pattern.

### 7.2 Type-System Usage

Generic parameters, macro usage, ownership annotations:

| Shape | Generic params | `@Witness` | `~Copyable` params | `sending` | Build time | Source files | Tuple-~Copy avoided |
|-------|---------------|------------|---------------------|-----------|-----------|--------------|---------------------|
| F | 0 | 2× | borrowing + consuming | 1 site | 1.27s | 10 | Yes |
| Dvm | 1 (in .map) | 2× | borrowing | 2 sites | 1.33s | 11 | Caveat (§5.2.3) |
| MG | 1 | 1× | N/A | 0 | 90.77s | 4 | Yes |
| GE | 1 (error) | 0× | borrowing + consuming | 2 sites | 0.98s | 11 | Yes |
| GO | 1 (ops) | 0× | borrowing + consuming | viral | 0.67s | 11 | Yes |
| DGS | 1 (substrate) | 0× | borrowing | viral | 0.65s | 11 | Yes |
| Tk | 0 | 3× | borrowing + consuming | 3 sites | 106.98s | 11 | Yes |
| Z | 3 (R, E, A) | 0× | N/A (R is generic) | sending R, sending A | 0.35s | 4 | Yes |
| E | 0 | 3× | N/A | compounding | 1.23s | 11 | Yes |
| M | 0 | 0× | consuming (attempted) | failed at rebind | 0.58s | 7 | Caveat (§5.10.3) |

### 7.3 Cognitive Dimensions Scoring (All Ten Shapes × Six Dimensions)

Abbreviations: L = Low, M = Medium, H = High.

| Shape | Visibility | Consistency | Viscosity | Role-expressiveness | Error-proneness | Abstraction |
|-------|------------|-------------|-----------|---------------------|-----------------|-------------|
| F | H | H | M | H | L | H |
| Dvm | H | H | M | H | M | H |
| MG | H | H | L | H | L | H |
| GE | M | H | M | H | M | H |
| GO | L | M | H | M | M | M |
| DGS | L | M | H | L | M | M |
| Tk | H | H | M | H | L | H |
| Z | L | M | H | M | H | M |
| E | H | H | M | H | L | M |
| M | M | L | H | M | H | L |

Lower is worse for Viscosity and Error-proneness; higher is better for
the other four. Shape F, Shape Dvm, Shape MG, and Shape Tk emerge with
the strongest profiles; Shapes Z, M, and DGS have the weakest.

### 7.4 Theoretical Pedigree Map

Which academic model each shape implements:

| Shape | Brachthäuser 2020 | Ahman & Bauer 2020 | Xie & Leijen 2021 | Schuster et al. 2020 | Wadler 1990 | Plotkin & Pretnar 2009 |
|-------|-------------------|---------------------|-------------------|----------------------|-------------|------------------------|
| F | Capability (primary) | Runner (separate) | Evidence vector | Value-type compilation | — | Handler |
| Dvm | Capability | Runner-to-runner transform | Evidence transform | — | — | Handler |
| MG | N/A (tooling) | N/A | Macro-indexed evidence | — | — | — |
| GE | Capability | Runner | Indexed evidence | — | — | Error-indexed handler |
| GO | Capability | Runner | Operation-indexed evidence | — | — | Generic handler |
| DGS | Capability | Runner | Substrate-indexed evidence | — | — | Handler with open signatures |
| Tk | Per-capability | Per-capability runner | Single-op evidence | — | — | Per-op handler |
| Z | Effect description | — | Monadic description | — | — | Monadic handler |
| E | Scoped capability | Runner in scope | Scoped evidence | — | — | Scoped handler |
| M | — | — | Linear evidence | — | Linear buffer | — |

### 7.5 Prior-Art Equivalence

Which production library each shape emulates:

| Shape | swift-nio | Tokio | monoio/glommio | Boost.Asio | Netty | Eio | ZIO | Go net | .NET Stream | Rust std::io |
|-------|-----------|-------|----------------|------------|-------|-----|-----|--------|-------------|--------------|
| F | Inspired (value-type vs ref) | — | — | — | — | — | — | — | — | — |
| Dvm | Constellation — domain packages | — | — | — | — | — | — | — | — | — |
| MG | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A | N/A |
| GE | — | Partial (Result indexes) | — | — | — | — | Error parameter | — | Partial | Result::map_err |
| GO | — | — | — | Template-based | — | — | — | — | — | — |
| DGS | — | — | — | Template-based | — | — | Env parameter | — | — | — |
| Tk | — | ✓ (primary emulation) | — | — | — | — | — | — | — | Read/Write traits |
| Z | — | — | — | — | — | — | ✓ (primary) | — | — | — |
| E | — | — | — | — | — | ✓ (primary) | — | — | — | — |
| M | — | — | ✓ (primary) | — | — | — | — | — | — | — |

### 7.6 Constraint Compliance

The six hard constraints (§2.2 RQ1) checked per shape:

| Shape | No protocols at public | No existentials | ~Copyable Kernel.Descriptor | Typed throws E2E | Region-based isolation | Swift 6.3 compile |
|-------|------------------------|-----------------|------------------------------|------------------|------------------------|-------------------|
| F | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Dvm | ✓ | ✓ | ✓ (with caveat on tuples) | ✓ (closure annot required) | ✓ | ✓ |
| MG | ✓ | ✓ | (if added) | ✓ | ✓ | ✓ |
| GE | ✓ | ✓ | ✓ | ✓ | ✓ (except `mapError`) | ✓ |
| GO | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| DGS | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Tk | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Z | ✓ | ✓ | ✓ (via sending R) | ✓ (closure annot required) | ✓ | ✓ |
| E | ✓ | ✓ | (if added) | ✓ | ✓ with tax | ✓ |
| M | ✓ | ✓ | Caveat (tuple-noncopy) | ✓ | Partial (rebind fails) | ✓ |

All ten shapes satisfy constraints 1, 2, and 6 (no protocols, no
existentials, Swift 6.3 compile). The discriminating constraints are
4 (typed throws closure inference) and 5 (region-isolation quirks).

### 7.7 Composition Operator Support

Which `swift-witnesses` operators and swift-native composition patterns
each shape supports:

| Shape | Witness.Recording | Witness.Scope | Witness.Values | Witness.Sequence | Witness.Cycle | .map | mapError | observe |
|-------|-------------------|----------------|----------------|------------------|----------------|------|----------|---------|
| F | ✓ (both) | ✓ (runner) | ✓ (typed slots) | ✓ | ✓ | via Dvm | via GE | ✓ |
| Dvm | ✓ (domain) | ✓ (if domain has lifecycle) | ✓ | ✓ | — | native | via GE | ✓ |
| MG | ✓ (per specialization) | ✓ | ✓ | ✓ | ✓ | — | — | ✓ |
| GE | Partial (per E spec) | ✓ | ✓ per E | — | — | via Dvm | native | ✓ |
| GO | — (ops not witnesses) | — | — | — | — | — | — | — |
| DGS | — | — | — | — | — | — | — | — |
| Tk | ✓ (per witness) | ✓ (Closer is scope-natural) | ✓ | ✓ | ✓ | — | — | ✓ |
| Z | — (monadic, not evidence-vector) | — | — | — | — | native | native | — |
| E | ✓ (sub-capabilities) | ✓ native | ✓ | ✓ | ✓ | — | — | ✓ |
| M | — (tuple returns) | — | — | — | — | — | — | — |

---

## 8. Prior Art: Production I/O Libraries

This section contextualizes each zoo shape in the production-library
ecosystem. For each library: formal shape extracted from the library's
public API, its closest zoo shape, and the features that may not
translate directly to Swift 6.3's type system.

Claims about library internals are cited where verifiable; claims that
cannot be verified are marked `[UNVERIFIED]` per §3.

### 8.1 Apple swift-nio

**Core type**: `Channel` protocol (reference type) + `ChannelPipeline`
+ `EventLoop`.

**Formal declaration** (extracted from the swift-nio repository, file
`Sources/NIOCore/Channel.swift`):

```swift
public protocol Channel: AnyObject, ChannelOutboundInvoker, Sendable {
    var allocator: ByteBufferAllocator { get }
    var closeFuture: EventLoopFuture<Void> { get }
    var pipeline: ChannelPipeline { get }
    var localAddress: SocketAddress? { get }
    var remoteAddress: SocketAddress? { get }
    var parent: Channel? { get }
    // ... many more members ...
}
```

**Closest zoo shape**: none directly. swift-nio's shape is explicitly
rejected by hard constraint 1 (no protocols at public surface) and
hard constraint 3 (ref-type `Channel` is not a value-type capability).
swift-nio is included in this section because it is the incumbent
Swift async I/O library; swift-io's shape is designed partly as a
corrective to nio's design choices.

**Features not in zoo**:
- `ChannelPipeline` / `ChannelHandler` — the inbound/outbound
  interception pipeline. Contextualized in
  [io-vs-nio-comparative-analysis.md](io-vs-nio-comparative-analysis.md)
  as a deliberate non-goal for swift-io.
- `EventLoopFuture<T>` — completion-future combinators. Subsumed by
  Swift's native async/await.
- `ByteBuffer` as mandatory interchange — direct conflict with
  "caller owns storage" contract.

**Primary source**: `https://github.com/apple/swift-nio` (inspected
commit at 2026-04-16 per
[io-vs-nio-comparative-analysis.md](io-vs-nio-comparative-analysis.md)
§Methodology).

### 8.2 Tokio

**Core traits**: `AsyncRead` and `AsyncWrite` in the `tokio::io` module.

**Formal declarations** (extracted from Tokio's published
documentation at `https://docs.rs/tokio/latest/tokio/io/`):

```rust
pub trait AsyncRead {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>>;
}

pub trait AsyncWrite {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<Result<usize, io::Error>>;
    fn poll_flush(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Result<(), io::Error>>;
    fn poll_shutdown(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Result<(), io::Error>>;
}
```

**Closest zoo shape**: Shape Tk (§5.7). The reader/writer/closer split
mirrors Tokio's two-trait split (with a subdivision: Tokio's
`AsyncWrite` includes write + flush + shutdown; Shape Tk's `Writer`
and `Closer` decompose further).

**Features not in zoo**:
- `poll_read` / `poll_write` based on `Future` + `Poll` state machine.
  Swift's `async`/`await` subsumes this via coroutines. The trait-
  based pattern does not apply directly.
- `Pin<&mut Self>` — self-referential types. Swift has no direct
  equivalent; `~Copyable` with `_read`/`_modify` coroutines covers
  related use cases.

**Structural equivalence**: high. Shape Tk is a faithful Swift
translation. Tokio's per-trait substitution story — a specific type
implements `AsyncRead` but not `AsyncWrite` — maps to per-witness
substitution (a test can provide a Reader without a Writer).

**Primary source**: Tokio's `tokio::io` module documentation at
`https://docs.rs/tokio/latest/tokio/io/` (version 1.x, verified
2026-04 release line).

### 8.3 monoio / glommio

**Core pattern**: rental-buffer for io_uring.

**Formal declarations** (extracted from monoio's GitHub repository at
`https://github.com/bytedance/monoio`):

```rust
impl<R: AsyncReadRent + ?Sized> AsyncReadRentExt for R {
    async fn read<B: IoBufMut>(&mut self, buf: B) -> BufResult<usize, B>;
}
pub type BufResult<T, B> = (Result<T>, B);
```

The key semantic: the buffer is **moved** into the operation
(ownership transferred), and the tuple return brings it back alongside
the result.

**Closest zoo shape**: Shape M (§5.10).

**Features not in zoo**:
- Rust's `IoBufMut` trait that abstracts over buffer types. Swift's
  equivalent is `Memory.Buffer` as a concrete type; protocol-based
  buffer abstraction requires a protocol, which is forbidden.
- Per-task runtime (`monoio::start`) — a scope-based runtime. Eio-
  style (Shape E) is the closer match in that respect.

**Structural equivalence**: medium. The rental shape translates
syntactically (`consuming Buffer` + `(Buffer, Int)` return), but
Swift's tuple-`~Copyable` limit and region-isolation rebind failure
make the shape strictly more constrained than Rust's.

**Primary source**: monoio source at
`https://github.com/bytedance/monoio` (inspected
2026-04-17 version line).

### 8.4 Boost.Asio

**Core type**: `io_context`. Template-based.

**Formal declaration** (extracted from Boost.Asio 1.88.0
documentation at
`https://www.boost.org/doc/libs/1_88_0/doc/html/boost_asio.html`):

```cpp
namespace boost::asio {
    class io_context : public execution_context { ... };
    template <typename Executor = any_io_executor>
    class basic_stream_socket { ... };
}
```

Template-parameterized operations accept backends via template
specialization.

**Closest zoo shape**: Shape GO (§5.5) and Shape DGS (§5.6).
Boost.Asio's template backend corresponds to the generic-ops or
generic-substrate pattern. The C++ template system resolves the
substitution at compile time.

**Features not in zoo**:
- SFINAE + concepts for template constraint. Swift's equivalent
  (protocols, generic constraints) is forbidden by hard constraint 1.
- Proactor-in-terms-of-reactor bridge. swift-io has
  independent implementations per strategy.

**Structural equivalence**: low. Boost.Asio's template-based shape
relies on C++ features (templates, SFINAE, CRTP) that do not have
direct Swift equivalents within the no-protocol constraint.

**Primary source**: Boost.Asio documentation
(`https://www.boost.org/doc/libs/1_88_0/doc/html/boost_asio.html`).

### 8.5 Netty (Java)

**Core abstraction**: `Channel` + `EventLoop` + `ChannelPipeline`.
Reference-typed. swift-nio is essentially a Swift port of Netty's
abstraction.

**Formal declaration** (extracted from Netty 4.1 Javadoc):

```java
public interface Channel extends AttributeMap, ChannelOutboundInvoker, Comparable<Channel> {
    ChannelId id();
    EventLoop eventLoop();
    ChannelPipeline pipeline();
    ByteBufAllocator alloc();
    boolean isActive();
    // ... many more methods ...
}
```

**Closest zoo shape**: none directly (same reasoning as swift-nio).

**Features not in zoo**:
- `ChannelPipeline` with bidirectional handler chain.
- `EventLoop.execute` as the scheduling primitive.
- `io_uring` support (incubating).

**Structural equivalence**: low. Netty's ref-type `Channel` is
rejected by hard constraint 3.

**Primary source**: Netty documentation at
`https://netty.io/4.1/api/`.

### 8.6 OCaml Eio

**Core type**: `Stdenv.t` — a first-class record of capabilities.

**Formal declaration** (from Eio 1.0 documentation at
`https://ocaml-multicore.github.io/eio/eio/Eio/Stdenv/index.html`):

```ocaml
type 'a t = < Eio.Stdenv.Base.t; .. > as 'a
(* Stdenv.t is an object with at least these capabilities *)
val stdin : < stdin : 'a; .. > -> 'a
val stdout : < stdout : 'a; .. > -> 'a
val net : < net : 'a; .. > -> 'a
val fs : < fs : 'a; .. > -> 'a
val clock : < clock : 'a; .. > -> 'a
val cwd : < cwd : 'a; .. > -> 'a
val domain_mgr : < domain_mgr : 'a; .. > -> 'a
```

The OCaml object-type `<...>` is a **structural type** — any object
with at least those fields satisfies it. Structural subtyping is an
OCaml feature; Swift does not have it.

**Closest zoo shape**: Shape E (§5.9).

**Features not in zoo**:
- Structural subtyping on the `Stdenv.t` type, allowing partial
  capability requirements like `< net; clock >`. Swift requires
  nominal types; Shape E's `Stdenv` struct has all three
  sub-capabilities mandatory.
- OCaml 5's effect handlers as the underlying mechanism
  (Sivaramakrishnan et al. 2021).
- Fiber-based scheduling.

**Structural equivalence**: medium. The scope form translates; the
structural capability type does not. Swift's nominal types force a
more rigid `Stdenv` struct.

**Primary source**: OCaml Eio documentation at
`https://ocaml-multicore.github.io/eio/`.

### 8.7 Scala ZIO

**Core type**: `ZIO[R, E, A]` — the three-parameter effect monad.

**Formal declaration** (from ZIO 2.x API at `https://zio.dev/`):

```scala
sealed abstract class ZIO[-R, +E, +A] extends Serializable {
    def map[B](f: A => B): ZIO[R, E, B]
    def flatMap[R1 <: R, E1 >: E, B](f: A => ZIO[R1, E1, B]): ZIO[R1, E1, B]
    def mapError[E1](f: E => E1): ZIO[R, E1, A]
    def provide(environment: R): ZIO[Any, E, A]
    // ... many combinators ...
}
```

The variance annotations (`-R`, `+E`, `+A`) and the subtype constraint
in `flatMap` (`R1 <: R`) are Scala-specific. Swift has invariant
generics and cannot express these subtyping relationships.

**Closest zoo shape**: Shape Z (§5.8).

**Features not in zoo**:
- Full ZIO fiber-based runtime.
- STM (Software Transactional Memory).
- Layer-based dependency injection (`ZLayer`).
- Scope-bounded resource management.

**Structural equivalence**: medium. The three-parameter monad type
translates; the combinators translate with typed-throws verbosity; the
fiber runtime does not translate (Swift has its own).

**Primary source**: ZIO's `https://zio.dev/` and the source code at
`https://github.com/zio/zio`.

### 8.8 Go `net` Package

**Core abstraction**: `net.Conn` interface. Hides all proactor/reactor
detail behind blocking-like `Read`/`Write` methods.

**Formal declaration** (from Go 1.22 standard library
`src/net/net.go`):

```go
type Conn interface {
    Read(b []byte) (n int, err error)
    Write(b []byte) (n int, err error)
    Close() error
    LocalAddr() Addr
    RemoteAddr() Addr
    SetDeadline(t time.Time) error
    SetReadDeadline(t time.Time) error
    SetWriteDeadline(t time.Time) error
}
```

Goroutine-based concurrency hides the dispatch. The runtime does the
netpoller integration invisibly.

**Closest zoo shape**: the `IO` per-op signature resembles Shape F's
capability witness (Go `Read`/`Write`/`Close` ↔ swift-io
`_read`/`_write`/`_close`), but Go hides the dispatch in the runtime
rather than exposing it as a separate runner. Goroutines are not
witnesses.

**Features not in zoo**:
- Runtime-hidden dispatch. swift-io's three-strategy design exposes
  dispatch as a runner witness.
- Goroutines. Swift's actors and tasks are the nearest analogue.

**Structural equivalence**: low at the type level; high at the
ergonomic level — swift-io aims for "sync-looking API, hidden
dispatch" in the same spirit.

**Primary source**: Go standard library at
`https://pkg.go.dev/net`.

### 8.9 .NET `Stream`

**Core type**: `System.IO.Stream`. Abstract reference class.

**Formal declaration** (from .NET 8.0 BCL):

```csharp
public abstract class Stream : MarshalByRefObject, IAsyncDisposable, IDisposable {
    public abstract bool CanRead { get; }
    public abstract bool CanWrite { get; }
    public abstract bool CanSeek { get; }
    public abstract long Length { get; }
    public abstract long Position { get; set; }
    public abstract int Read(byte[] buffer, int offset, int count);
    public abstract void Write(byte[] buffer, int offset, int count);
    public virtual Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken);
    // ... etc ...
}
```

Reference-typed abstract class.

**Closest zoo shape**: none directly (ref-type, rejected by hard
constraint 3).

**Features not in zoo**:
- `CanRead`/`CanWrite`/`CanSeek` capability introspection. Swift
  would use separate witnesses per capability (Shape Tk).
- `CancellationToken`. swift-io uses `withTaskCancellationHandler`.

**Structural equivalence**: low.

**Primary source**: .NET API docs at
`https://learn.microsoft.com/en-us/dotnet/api/system.io.stream`.

### 8.10 Rust `std::io`

**Core traits**: `Read`, `Write`, `BufRead`, `Seek`.

**Formal declaration** (from Rust 1.83 standard library):

```rust
pub trait Read {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize>;
    // ... default-impl methods ...
}

pub trait Write {
    fn write(&mut self, buf: &[u8]) -> Result<usize>;
    fn flush(&mut self) -> Result<()>;
    // ... default-impl methods ...
}
```

Synchronous (blocking) traits. Separate from async I/O (Tokio, etc.).

**Closest zoo shape**: Shape Tk (§5.7) — synchronous per-capability
traits translate to per-witness structs with the `async` annotation
removed.

**Features not in zoo**:
- Default implementations on traits. Swift can do similar via
  protocol extensions, which are forbidden.
- Blocking semantics. swift-io is async-only.

**Structural equivalence**: medium. The per-capability split is
faithful; the default-impl pattern is not translatable.

**Primary source**: Rust std documentation at
`https://doc.rust-lang.org/std/io/`.

---

## 9. Academic Foundations

This section surveys the academic literature that informs the zoo
shapes. Each subsection names the model, summarizes its claim, and
maps it to one or more zoo shapes.

### 9.1 Algebraic Effects and Handlers

**Plotkin & Pretnar 2009** ("Handlers of Algebraic Effects", ESOP) —
the foundational paper. An effect signature `Σ = {op_1, ..., op_n}`
is a set of operations; a handler provides implementations for the
operations as a set of clauses. Computations using the effect
signature are interpreted by the handler.

**Leijen 2017** ("Type Directed Compilation of Row-Typed Algebraic
Effects", POPL) — row-typed effect rows, compiling effect handlers
efficiently by tagging operations with their source row.

**Kammar, Lindley, Oury 2013** ("Handlers in Action", ICFP) —
practical handler implementation and type-directed compilation.

**Ahman & Pretnar 2021** ("Asynchronous Effects", POPL) — the
formal framework where effect execution decomposes into *signalling*
(operation requested) and *interrupting* (result delivered). Reactor
= signal readiness, then perform synchronously. Proactor = signal
operation, then interrupt with completion. Both coexist under the
same effect signature with different handlers.

**Relevance to zoo**: all ten shapes are instances of the algebraic-
effects-handler tradition. Shape F's `IO` witness has four operations
(read, write, close, ready); the runner has two (executor, shutdown).
Shape Tk subdivides into three single-operation signatures. Shape Z's
`IO<R, E, A>` is the monadic counterpart of an effect computation.

### 9.2 Runners Calculus

**Ahman & Bauer 2020** ("Runners in Action", ESOP) — the primary
theoretical model for swift-io's capability/runner split. A runner
manages external resources at the computation boundary, provides
operations to the computation, and guarantees linear resource use and
finalization. Formally:

- Runner `R = <ops, fin>` where `ops` are the operations and `fin` is
  the finalization action.
- Computation `M = let x = op(args) in M'` performs an operation and
  continues.
- Execution `using R run M` binds the runner to the computation.

**Mapping to swift-io**:

| Ahman & Bauer | swift-io |
|---------------|----------|
| Runner | `IO.Runner` witness (Shape F) or `IO` witness (Shape B) |
| Runner's operations | `_read`, `_write`, `_accept`, `_close`, `_ready` (capability) |
| Finalization | `_shutdown` on `IO.Runner` (Shape F) |
| `using R run M` | The consumer's `try await io.read(...)` call, bound to the runner impl |
| Linear resource use | `consuming Kernel.Descriptor` on `_close` |

Shape F makes the runner a first-class witness, matching Ahman &
Bauer's model most directly. Shape B subsumes the runner into the
capability, diluting the model.

### 9.3 Effects as Capabilities

**Brachthäuser, Schuster, Ostermann 2020** ("Effects as Capabilities:
Effect Handlers and Lightweight Effect Polymorphism", OOPSLA).
Capabilities are second-class: passed as arguments, cannot escape
scope. The paper proves capabilities are equivalent to effect
handlers via compilation: a handler is realized as a capability
passed through the call chain; effect operations are realized as
calls on the capability.

**Mapping to zoo**: Shape F's `IO` witness IS a capability — a
value-type record of operations, passed as an argument, not escaping
the consumer's scope. Shape E's `Stdenv` nested capabilities are the
same pattern in a scoped form. Shape Z's `R` environment is Scala
ZIO's emulation of capability passing via a monadic index.

### 9.4 Evidence Passing

**Xie & Leijen 2021** ("Generalized Evidence Passing for Effect
Handlers", ICFP). Effect handlers can be compiled by passing an
*evidence vector* — a record of handler function implementations —
alongside the program's normal arguments. The evidence is
structurally a record; lookup is a record-field access; no dynamic
dispatch is needed.

**Mapping to zoo**: all witness-based shapes (F, Dvm, MG, GE, GO,
DGS, Tk, E) are evidence vectors. The witness struct *is* the
evidence. Shape Z uses a different compilation (monadic description
trees) but is theoretically equivalent under
monads-≡-effect-handlers.

### 9.5 Capability-Passing Compilation

**Schuster, Brachthäuser, Ostermann 2020** ("Compiling Effect
Handlers in Capability-Passing Style", ICFP). The paper demonstrates
a **150× speedup** from capability-passing compilation over dynamic
handler lookup. Capability-passing is the fastest known compilation
strategy for effect handlers, dominating continuation-based and
stack-search-based approaches.

**Implication for zoo**: any witness-based shape (F, Dvm, Tk, E, and
the macro-generic variants) uses capability-passing compilation
implicitly — the witness IS the capability. Schuster's 150× applies
directly. Shape Z does not benefit from this; its combinator
chains introduce per-call closure allocation.

### 9.6 Session Types

**Honda, Vasconcelos, Kubo 1998** ("Language Primitives for
Structured Communication", ESOP). Session types describe communication
protocols as types, enabling static verification of protocol adherence.

**Caires & Pfenning 2010** ("Session Types as Intuitionistic Linear
Propositions", CONCUR). Session types correspond to linear logic
propositions.

**Relevance to zoo**: session types are tangential. swift-io's
capability witness has the shape `?Read.?Read.!Close` (repeated reads
then one close) but does not explicitly enforce this as a session
type. Shape M's rental pattern is *closer* to a session type
formulation ("read returns buffer so a subsequent read can be bound
to it") but stops short of a full session type.

### 9.7 Linear Types

**Wadler 1990** ("Linear Types Can Change the World!"). Linear types
constrain values to be used exactly once. Applied to I/O, linear types
enforce resource safety — a file descriptor passed linearly cannot be
leaked.

**Bernardy, Boespflug, Newton, Peyton Jones, Spiwack 2018** ("Linear
Haskell", POPL). Haskell's linear-arrow calculus; precedent for
Swift's `consuming` parameter.

**Relevance to zoo**: Swift's `~Copyable` is a linear-types
mechanism. All shapes that use `consuming Kernel.Descriptor` on `_close`
(F, Dvm, GE, GO, Tk, E) employ linear-type discipline. Shape M's
rental pattern is a direct linear-type encoding of io_uring's buffer
ownership.

### 9.8 Swift-Specific Language Features

The zoo shapes leverage several Swift-specific features; each with its
Swift Evolution (SE) proposal.

- **SE-0413 Typed Throws** — `throws(E)` on functions and closures.
  Used in every shape.
- **SE-0414 Region-Based Isolation** — introduces regions as the
  basis for isolation. Foundation for `sending`.
- **SE-0430 `sending` Parameter and Result Values** — region transfer
  semantics. Used in Shapes F, Dvm, GE, Z, E.
- **SE-0417 Task Executor Preference** — advisory preference.
  Informs the shared-executor discussion (Shape F's runner concern).
- **SE-0392 Custom Actor Executors** — `isolated Actor` parameters.
  Enables the shared-executor pattern.
- **SE-0461 Run Nonisolated Async Functions on Caller's Actor** —
  enables zero-hop dispatch from consumer actors.
- **SE-0390 Noncopyable Structs and Enums** — `~Copyable` types.
  `Kernel.Descriptor` is `~Copyable`.
- **SE-0456 Span** — `Span<T>` as non-owning buffer view. Used by
  the real `Memory.Buffer`; the sketches use Sendable stand-ins.
- **SE-0458 Strict Memory Safety** — `.strictMemorySafety()` flag.
  Enabled across the ecosystem.

### 9.9 Region Calculus

**Tofte & Talpin 1997** ("Region-Based Memory Management",
Information and Computation). The foundational paper on regions as a
memory-management discipline.

**Relevance to zoo**: Swift's `sending` parameters (SE-0430) are
a runtime-checked region-isolation mechanism. The theoretical
underpinning is Tofte & Talpin's region calculus, though Swift's
implementation is not a direct port. The region checker's
flow-sensitive limitation (exhibited in Shape M's rebind failure)
is a specific weakness of the checker, not of the underlying theory.

---

## 10. Decision Framework

This section does NOT recommend a shape. Instead, it enumerates the
dimensions along which a decision document would evaluate the shapes,
and identifies which shapes are eliminated by hard constraint
violations or structural redundancy.

### 10.1 Weighted Criteria

The capability/runner split research
([io-witness-capability-runner-split.md](../swift-io/Research/io-witness-capability-runner-split.md))
established six weighted criteria for the B/F/G comparison. This
analysis extends them to all ten shapes:

| # | Criterion | Weight | Applied to zoo |
|---|-----------|--------|----------------|
| C1 | Preserves Shape B axioms | High | Value-type, Sendable-compatible, typed throws, ~Copyable-friendly |
| C2 | Capability axiom purity | High | Capability witness exposes only operations; lifecycle separated |
| C3 | Consumer API ergonomics | High | Shared-executor pattern single-line; no viral generics |
| C4 | Compositionality with swift-witnesses | High | `Witness.*` operators apply uniformly |
| C5 | Testability symmetry | Medium | `*.unimplemented()` generated for each witness |
| C6 | Migration cost from current Shape B | Medium | Number of call-site churns |

A decision document will apply weights and score each shape on each
criterion, using the data in §§5 and 7 as input.

### 10.2 Trade-off Space

The primary trade-offs discovered:

**Trade-off A: Unified vs. split capability witness**.
- Unified (Shape F, Shape GE) — fewer parameters at call sites, uniform
  naming.
- Split (Shape Tk) — finer-grained substitution, more parameters.

**Trade-off B: Concrete vs. generic witness type**.
- Concrete (Shape F) — no viral specialization, stable naming.
- Generic error only (Shape GE) — domain-specific errors, moderate
  virality.
- Generic ops (Shape GO) — aggressive parameterization, high
  virality.

**Trade-off C: Value-type capability vs. scoped capability**.
- Value-type (Shape F) — pass around freely, store on actors.
- Scoped (Shape E) — structured lifetime; compounding `sending`-tax.

**Trade-off D: Native combinators vs. `swift-witnesses` composition**.
- `Witness.*` (Shape F, Tk, Dvm, E) — uniform composition library.
- Monadic (Shape Z) — native combinators but orthogonal to
  `swift-witnesses`.

**Trade-off E: Ownership-enforced rental vs. borrow + handshake**.
- Rental (Shape M) — pedantically correct but ergonomically hostile.
- Borrow + handshake (swift-io's current approach) — equivalent safety
  via cancellation handshake.

### 10.3 Elimination Logic

Shapes eliminated by hard-constraint violations or structural redundancy:

**Structurally eliminated (hard-constraint violation)**:
- **Shape Z** — no executor-binding story. Hard constraint 4 (criterion
  C4 of capability/runner split) requires the shared-executor pattern.
  Shape Z cannot express `io.unownedExecutor`.

**Structurally eliminated (redundancy)**:
- **Shape GO** — redundant with Shape Dvm (if `Ops` records become
  `@Witness`, shape collapses to Dvm with an envelope).
- **Shape DGS** — strictly inferior to Shape Dvm on every ergonomic
  dimension.

**Structurally eliminated (ergonomic cost)**:
- **Shape M** — rental's rebind loop ergonomics, tuple-noncopyable
  limit, region-checker rebind failure. Current swift-io approach
  dominates.
- **Shape E** — scope form's compounding `sending`-tax for
  long-running servers. Shape F subsumes the pattern.

**Remaining candidates**:
- **Shape F** (capability + runner split).
- **Shape Dvm** (domain composition) — as a composition mechanism on
  top of F, not a standalone alternative.
- **Shape GE** (generic error) — as an addition to F, making
  `IO<LeafError>`.
- **Shape MG** (macro generic compatibility) — enables GE, GO, DGS
  as macro-based.
- **Shape Tk** (per-capability split) — alternative decomposition axis.

### 10.4 Remaining Candidates and Distinguishing Trade-offs

Among the non-eliminated shapes:

**F vs. Tk**: unified vs. split. F has one capability witness with
four closures; Tk has three. For swift-sockets' invariant usage
pattern (accept → read → write → close), F matches better. For
fine-grained testing, Tk offers per-capability mocks.

**F+GE vs. F alone**: error-generic capability vs. flat `IO.Error`.
GE enables `IO<Socket.Error>` domain-precise catches; F alone uses
one flat error type. The decision depends on how granular swift-io
wants its error domains.

**F+Dvm vs. F alone**: with vs. without domain-via-map. Dvm is not
an alternative; it is the natural mechanism for Sockets/File/Pipe
domain witnesses to be derived from F. Without Dvm, each domain
package would declare its own IO from scratch — more duplication.

**F+MG vs. F hand-written**: macro-generic vs. manual. MG enables
macro-based expansion for generic variants. For F+GE, MG allows
`@Witness public struct IO<LeafError: Error>`. Hand-written remains
the reference implementation.

---

## 11. Synthesis

### 11.1 What Each Variant Teaches

- **F** — the capability/runner split is the clean realization of
  Brachthäuser + Ahman & Bauer. The runner witness as a first-class
  entity enables `Witness.Scope` to bind lifetimes naturally.
- **Dvm** — domain-witness composition is cleanly achievable via
  `.map` without protocols or existentials.
- **MG** — the `@Witness` macro handles generics surprisingly well.
  Cold build times are significant for generic specializations.
- **GE** — error-indexed capability is viable but introduces a
  generic parameter with moderate virality; `mapError` cannot produce
  a `sending` result.
- **GO** — operation-set-indexed capability compiles but is
  structurally redundant with Dvm.
- **DGS** — substrate-indexed capability is strictly inferior to Dvm.
- **Tk** — per-capability split is clean but verbose at multi-capability
  call sites; bundle mitigates.
- **Z** — monadic IO<R, E, A> compiles, eliminates R: Sendable under
  region isolation, but no executor-binding story rules it out.
- **E** — scope form adds compounding `sending`-tax and is subsumed
  by value-type capability passing.
- **M** — rental pattern is pedantically correct but ergonomically
  hostile; demonstrates `consuming`/`sending` complementarity.

### 11.2 Candidate Finalists

After elimination, the finalists are **Shape F**, possibly extended
with **Shape GE** (generic error) and complemented by **Shape Dvm**
(domain composition), with the **Shape MG** finding as a tooling
enabler. **Shape Tk** is an alternative decomposition axis that
competes with F's unified shape on visibility vs. substitution
granularity.

Head-to-head:

| Criterion | Shape F | Shape F + GE | Shape Tk | Shape Tk + GE |
|-----------|---------|--------------|----------|---------------|
| No generic params at consumer | ✓ | — (E is generic) | ✓ | — |
| Error domain specialization | One flat IO.Error | Per-domain `IO<E>` | One flat IO.Error | Per-domain |
| Call-site parameter count | 1 (bundle) | 1 | 3 (or bundle) | 3 (or bundle) |
| Capability substitution granularity | Whole capability | Whole | Per-capability | Per-capability |
| Build time (sketch cold) | 1.27s | 0.98s hand-written | 106.98s | — |
| Shared-executor pattern | ✓ | ✓ | ✓ | ✓ |
| `Witness.*` composition | Full | Full per spec | Full per witness | — |

No single row dominates; the decision document must apply weights
specific to swift-io's priorities.

### 11.3 Compatible Combinations

The finalists are compatible in specific ways:

- **F + Dvm** — fully compatible. Dvm is F's natural domain-composition
  mechanism.
- **F + GE** — fully compatible. `IO<LeafError>` becomes the
  capability witness; `IO.Runner` stays error-agnostic.
- **F + MG** — fully compatible. MG's finding makes F's witnesses
  macro-based-amenable if they become generic.
- **F + Tk** — alternative decomposition: per-capability witnesses
  instead of one unified. Not directly compatible without choosing
  one or the other.
- **F + GE + Dvm** — fully compatible. A base `IO<IO.Error>` is the
  reference; `Socket.IO = IO<Socket.Error>.map { ... }`; each domain
  has its own error type and its own domain witness.
- **F + GE + Dvm + MG** — the maximum-feature combination. All
  orthogonal features enabled.

Incompatible combinations:

- **Z + anything** — Z's monadic shape doesn't compose with
  witnesses.
- **M + F** — M's rental return shape conflicts with F's `_read`
  return.
- **E + F** — E's scope form and F's value-type bundle address the
  same concern; pick one.

### 11.4 Open Questions for the Follow-up Selection Analysis

A decision document should address:

1. **Error granularity**: flat `IO.Error` or per-domain `IO<E>`?
   Related: can the `mapError` region-inheritance problem be worked
   around for consumer patterns?
2. **Capability granularity**: one unified witness (F) or per-capability
   split (Tk)? Related: does swift-sockets actually need per-capability
   mocks?
3. **Domain composition mechanism**: Dvm (`.map`) is recommended; are
   there alternatives that have not been captured in the zoo?
4. **Macro budget**: how many `@Witness` structs is acceptable in the
   core? Tk's 3-witness sketch took 106.98s to build; a larger set
   scales linearly.
5. **Migration path**: from current Shape B (single `IO` witness with
   `_unownedExecutor`) to Shape F (split into `IO` + `IO.Runner`).
   How many call sites change?
6. **Runner operations**: Shape F's runner has `_executor` and
   `_shutdown`. What is the v1 minimal surface? Naming (`_name`),
   statistics (`_statistics`) are deferred.
7. **Shared-executor pattern**: does the decision document mandate
   this as the recommended pattern, or present it as an optimization
   opt-in?

---

## 12. Outcome

**Status**: IN_PROGRESS. This document awaits a follow-up selection
analysis.

### 12.1 Summary of Findings

The ten zoo shapes cluster into three families:

1. **Capability witnesses** (F, Dvm, Tk) — satisfy all hard constraints,
   compose with `Witness.*` operators, support `~Copyable` descriptors
   and typed throws cleanly.
2. **Parameterized witnesses** (GE, GO, DGS, Z, with MG as tooling
   enabler) — introduce generic parameters with virality ranging from
   benign (GE) to severe (GO, DGS).
3. **Scope and rental variants** (E, M) — use scope or rental patterns
   that introduce compounding `sending`-tax or ergonomic cost.

Eliminated by hard constraints or redundancy: Z (no executor binding),
GO (redundant with Dvm), DGS (inferior to Dvm), M (ergonomic cost),
E (compounding tax subsumed by F).

Remaining finalists: F, Dvm as F's composition mechanism, GE as F's
error-generic extension, Tk as alternative decomposition axis, MG
as tooling enabler.

### 12.2 What This Document Does Not Decide

Which shape swift-io should adopt. That decision integrates the
findings here with:

- Implementation constraints (code-base churn, CI time budget).
- Ship schedule (swift-io Phase 3 milestones).
- Consumer-library priorities (swift-sockets Phase 2 status).
- Ecosystem cohesion (swift-file-system's existing dependency on
  `IO.Blocking.shared`).

A follow-up decision document will take these inputs and arrive at
the selected shape. The present document's role is to provide the
comparative data that decision document needs.

---

## Appendices

### Appendix A: Glossary

- **@Witness** — macro that expands a struct of closures into a
  witness pattern with auto-generated test helpers.
- **Brachthäuser 2020** — "Effects as Capabilities", the paper establishing
  that value-type capabilities are equivalent to effect handlers.
- **Capability** — a value-type record of operations, per Brachthäuser.
- **consuming** — Swift parameter convention that transfers ownership
  to the callee.
- **borrowing** — Swift parameter convention granting read-only access.
- **Domain witness** — a specialized witness for a specific I/O domain
  (Socket.IO, File.IO).
- **Evidence vector** — Xie & Leijen's name for the witness structure.
- **Kernel.Descriptor** — `~Copyable` wrapper around a raw file
  descriptor.
- **mapError** — combinator that wraps each closure with an error
  transform.
- **Proactor** — I/O pattern where the kernel performs the operation
  and notifies on completion (io_uring, IOCP).
- **Reactor** — I/O pattern where the application polls for readiness
  and performs the syscall itself (kqueue, epoll).
- **Runner** — a lifecycle/scheduling value, per Ahman & Bauer.
- **sending** — Swift parameter/result annotation that transfers
  region ownership.
- **Shape** — a specific witness declaration strategy in the zoo.
- **Substrate** — generic-parameter name for the base IO in a
  generic domain witness.
- **Witness** — the evidence-vector pattern: struct of closures.

### Appendix B: Evaluation Criteria Full Definitions

Each criterion used in §§5.x.11 and §7.3 is defined below. Scores
are ordinal {low, medium, high} relative to the cohort.

**Visibility**: the degree to which the operations or capabilities
exposed by the shape can be identified by reading its type
declaration. Example: Shape F's four named closures are immediately
visible; Shape Z's single `run` closure hides the operations.

**Consistency**: the degree to which related shapes or related
elements of a shape share structure. Example: Shape F's capability and
runner witnesses have the same `@Witness public struct` form.

**Viscosity**: the resistance of the shape to change. Example: adding
a new operation to Shape F requires updates at the witness declaration,
the factory, and all consumer call sites exercising it. Adding to
Shape GO is viscous through the generic parameter.

**Role-expressiveness**: the degree to which each element's role is
clear from its name and position. Example: Shape F's `_executor` and
`_shutdown` on the runner announce their roles; Shape DGS's
"substrate" is opaque.

**Error-proneness**: the degree to which the shape invites consumer
mistakes. Example: Shape M's rental pattern invites forgetting to
re-bind the returned buffer.

**Abstraction**: the degree to which the shape admits building higher-
level abstractions on top. Example: Shape F admits `Witness.Recording`
/ `Witness.Scope` / `Witness.Values` composition; Shape M does not.

### Appendix C: Raw Sketch Source Index

| Shape | Directory | Source files | Build time | Build status |
|-------|-----------|--------------|------------|--------------|
| F | io-witness-shape-f | 10 | 1.27s | PASS |
| Dvm | io-witness-domain-via-map | 11 | 1.33s | PASS (with caveats) |
| MG | io-witness-macro-generic-compat | 4 | 90.77s | PASS (surprise) |
| GE | io-witness-generic-error | 11 | 0.98s | PASS |
| GO | io-witness-generic-ops | 11 | 0.67s | PASS |
| DGS | io-witness-domain-generic-substrate | 11 | 0.65s | PASS (redundant) |
| Tk | io-witness-tokio-style | 11 | 106.98s | PASS |
| Z | io-witness-zio-style | 4 | 0.35s | PASS (viable under region isolation) |
| E | io-witness-eio-style | 11 | 1.23s | PASS |
| M | io-witness-monoio-style | 7 | 0.58s | PASS |

Source file count reflects the [API-IMPL-005] one-type-per-file refactor
applied 2026-04-17.

### Appendix D: Cognitive Dimensions Rubric

Scoring at §5.x.11 follows this rubric:

**Visibility — High**: operations declared as named closures in a
struct; the consumer can see the full signature at the declaration
site. *Medium*: operations accessible but require one extra layer
(e.g., through an intermediate `ops` field). *Low*: operations
hidden behind a generic parameter or a single opaque closure.

**Consistency — High**: all witnesses in the shape share the same
declaration pattern; all closures have the same structural template.
*Medium*: minor variation between siblings. *Low*: significant
structural variation.

**Viscosity — Low**: changes to one element do not propagate to others.
*Medium*: changes propagate to a bounded set of call sites.
*High*: changes propagate virally (generic parameter changes).

**Role-expressiveness — High**: each element's name announces its
role directly. *Medium*: names require domain knowledge to interpret.
*Low*: generic placeholders dominate.

**Error-proneness — Low**: the shape's type system catches misuse
at compile time. *Medium*: most errors caught, some runtime
surprises possible. *High*: latent bugs possible (e.g., forgotten
re-bind).

**Abstraction — High**: the shape composes with a rich ecosystem of
operators. *Medium*: the shape composes with a limited set.
*Low*: the shape has no standard composition.

### Appendix E: SLR Search Strategy Details

**Databases searched**:

1. ACM Digital Library (`https://dl.acm.org/`) — for POPL, ICFP,
   OOPSLA, ESOP proceedings.
2. arXiv (`https://arxiv.org/`) — for preprints on effect systems.
3. Microsoft Research publications
   (`https://www.microsoft.com/en-us/research/publication/`) — for
   Daan Leijen's work on effect handlers.
4. Swift Forums (`https://forums.swift.org/`) — for Swift-specific
   discussion on concurrency, typed throws, region isolation.
5. Swift Evolution (`https://github.com/swiftlang/swift-evolution`) —
   for official proposals.

**Date range**: 2009–2026-04. The earliest academic reference is
Plotkin & Pretnar 2009; the latest Swift Evolution proposal is SE-0461
(2025).

**Screening**: approximately 150 titles inspected; 22 academic papers
admitted; 10 production libraries surveyed; 9 SE proposals cited; 12
Swift Institute research documents cited.

**Full list**: see Appendix G.

### Appendix F: Threats to Validity (Full Enumeration)

**Construct validity**:

1. Compile success is necessary but not sufficient for shape-level
   feasibility. A shape can compile and still be unusable at scale.
   *Mitigation*: caveats enumerated per shape in §5.x.
2. Cognitive Dimensions are ordinal, not cardinal. Ranking is
   meaningful; absolute scores are not. *Mitigation*: §7.3 presents
   ordinal bands, not numeric scores.
3. "Compatibility" between shapes (§11.3) is a structural claim about
   type-level composition, not a runtime claim. *Mitigation*:
   compatibility claims are tested against the sketches' actual
   constructions.

**Internal validity**:

1. Sketch size varies (4 to 11 files). Line counts may be confounded.
   *Mitigation*: line counts are recorded but not primary comparators.
2. Author selection bias toward Shape F given the prior research
   trajectory. *Mitigation*: equal-template structure in §5;
   elimination logic (§10.3) states criteria that apply uniformly.
3. Build times are cold-build only. Incremental build performance
   is not measured. *Mitigation*: build times are reported with
   "cold" tag; incremental performance noted as a future measurement
   need.

**External validity**:

1. The zoo is ten shapes. Many plausible shapes are not in the zoo
   (algebraic effects via swift-effects, delimited continuations, any
   shape relying on protocols). *Mitigation*: §2.2 RQ1 states the
   hard constraints that narrow the design space.
2. Results are specific to Swift 6.3 release. Future Swift versions
   may differ. *Mitigation*: §1.3 records the exact toolchain.
3. swift-io's constellation (swift-sockets, swift-file-system) may
   have needs not surfaced in this analysis. *Mitigation*:
   §1.1 references the companion `io-vs-nio-comparative-analysis.md`
   and `nio-inspired-capability-additions.md` for capability-gap
   analysis.

**Reliability**:

1. Re-running the zoo sketches under a different toolchain (e.g.,
   Swift 6.4-dev) may produce different compile outcomes. Example:
   Shape M's rebind failure is specific to the 6.3 region-checker.
   *Mitigation*: each EXPERIMENT.md locks in date and toolchain.
2. Dependent sub-experiments (e.g., GE depends on MG's finding) may
   change if one sub-experiment is re-run under different conditions.
   *Mitigation*: dependencies documented in the per-variant analysis.

### Appendix G: Reference List

#### Academic Papers

1. **Ahman, D. & Bauer, A.** 2020. "Runners in Action." ESOP 2020.
   Available at `https://arxiv.org/abs/1910.11629`.

2. **Ahman, D. & Pretnar, M.** 2021. "Asynchronous Effects." POPL 2021.

3. **Bernardy, J-P., Boespflug, M., Newton, R., Peyton Jones, S., &
   Spiwack, A.** 2018. "Linear Haskell: Practical Linearity in a
   Higher-Order Polymorphic Language." POPL 2018.

4. **Blackwell, A.F., Britton, C., Cox, A., Green, T.R.G., Gurr, C.,
   Kadoda, G., Kutar, M.S., Loomes, M., Nehaniv, C.L., Petre, M.,
   Roast, C., Roes, C., Wong, A., & Young, R.M.** 2001. "Cognitive
   Dimensions of Notations: Design Tools for Cognitive Technology."
   Cognitive Technology: Instruments of Mind, LNCS 2117.

5. **Brachthäuser, J.I., Schuster, P., & Ostermann, K.** 2020.
   "Effects as Capabilities: Effect Handlers and Lightweight Effect
   Polymorphism." OOPSLA 2020.

6. **Caires, L. & Pfenning, F.** 2010. "Session Types as
   Intuitionistic Linear Propositions." CONCUR 2010.

7. **De Goes, J.** ZIO library documentation and presentations at
   `https://zio.dev/`.

8. **Filinski, A.** 1994. "Representing Monads." POPL 1994.

9. **Green, T.R.G.** 1989. "Cognitive Dimensions of Notations."
   People and Computers V.

10. **Green, T.R.G. & Petre, M.** 1996. "Usability Analysis of Visual
    Programming Environments: A 'Cognitive Dimensions' Framework."
    Journal of Visual Languages and Computing.

11. **Honda, K., Vasconcelos, V.T., & Kubo, M.** 1998. "Language
    Primitives and Type Discipline for Structured Communication-Based
    Programming." ESOP 1998.

12. **Kammar, O., Lindley, S., & Oury, N.** 2013. "Handlers in
    Action." ICFP 2013.

13. **Kitchenham, B.** 2004. "Procedures for Performing Systematic
    Reviews." Keele University Technical Report TR/SE-0401.

14. **Kitchenham, B. & Charters, S.** 2007. "Guidelines for
    performing Systematic Literature Reviews in Software Engineering."
    EBSE Technical Report EBSE-2007-01.

15. **Leijen, D.** 2017. "Type Directed Compilation of Row-Typed
    Algebraic Effects." POPL 2017.

16. **Miller, M.S.** 2006. "Robust Composition: Towards a Unified
    Approach to Access Control and Concurrency Control." PhD Thesis,
    Johns Hopkins University.

17. **Peyton Jones, S. & Wadler, P.** 1993. "Imperative Functional
    Programming." POPL 1993.

18. **Pirog, M., Polesiuk, P., & Sieczkowski, F.** 2019. "Typed
    Equivalence of Effect Handlers and Delimited Control." FSCD 2019.

19. **Plotkin, G. & Pretnar, M.** 2009. "Handlers of Algebraic
    Effects." ESOP 2009.

20. **Schmidt, D.C.** 1995. "Reactor: An Object Behavioral Pattern
    for Demultiplexing and Dispatching Handles for Synchronous Events."
    Pattern Languages of Program Design.

21. **Schmidt, D.C.** 1997. "Proactor: An Object Behavioral Pattern
    for Demultiplexing and Dispatching Handlers for Asynchronous
    Events." Pattern Languages of Program Design.

22. **Schmidt, D.C., Stal, M., Rohnert, H., & Buschmann, F.** 2000.
    "Pattern-Oriented Software Architecture, Volume 2: Patterns for
    Concurrent and Networked Objects." Wiley.

23. **Schuster, P., Brachthäuser, J.I., & Ostermann, K.** 2020.
    "Compiling Effect Handlers in Capability-Passing Style."
    ICFP 2020.

24. **Sivaramakrishnan, K.C., Dolan, S., White, L., Jaffer, T.,
    Kelly, S., Sahoo, A., Parimala, S., Dhiman, A., & Madhavapeddy, A.**
    2021. "Retrofitting Effect Handlers onto OCaml." PLDI 2021.

25. **Tofte, M. & Talpin, J-P.** 1997. "Region-Based Memory
    Management." Information and Computation.

26. **Wadler, P.** 1990. "Linear Types Can Change the World!"
    Programming Concepts and Methods.

27. **Wadler, P.** 1992. "The Essence of Functional Programming."
    POPL 1992.

28. **Xie, N. & Leijen, D.** 2021. "Generalized Evidence Passing for
    Effect Handlers." ICFP 2021.

29. **Yin, R.K.** 2003. "Case Study Research: Design and Methods."
    3rd ed. Sage Publications.

#### Swift Evolution Proposals

30. **SE-0390** — Noncopyable Structs and Enums. Swift Evolution,
    2023. `https://github.com/swiftlang/swift-evolution/blob/main/proposals/0390-noncopyable-structs-and-enums.md`

31. **SE-0392** — Custom Actor Executors. Swift Evolution, 2023.
    `https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md`

32. **SE-0413** — Typed Throws. Swift Evolution, 2023.
    `https://github.com/swiftlang/swift-evolution/blob/main/proposals/0413-typed-throws.md`

33. **SE-0414** — Region-Based Isolation. Swift Evolution, 2024.
    `https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md`

34. **SE-0417** — Task Executor Preference. Swift Evolution, 2024.
    `https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md`

35. **SE-0430** — `sending` Parameter and Result Values. Swift
    Evolution, 2024.
    `https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md`

36. **SE-0431** — `@isolated(any)` Function Types. Swift Evolution,
    2024.
    `https://github.com/swiftlang/swift-evolution/blob/main/proposals/0431-isolated-any-functions.md`

37. **SE-0456** — Span. Swift Evolution, 2024.
    `https://github.com/swiftlang/swift-evolution/blob/main/proposals/0456-stdlib-span-properties.md`

38. **SE-0458** — Strict Memory Safety. Swift Evolution, 2025.
    `https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md`

39. **SE-0461** — Run Nonisolated Async Functions on Caller's Actor by
    Default. Swift Evolution, 2025.
    `https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md`

#### Swift Institute Research Documents

40. **io-witness-design-literature-study.md** v4.0, 2026-04-14.
    `/Users/coen/Developer/swift-foundations/swift-io/Research/
    io-witness-design-literature-study.md`

41. **io-witness-capability-runner-split.md** v1.0, 2026-04-17.
    `/Users/coen/Developer/swift-foundations/swift-io/Research/
    io-witness-capability-runner-split.md`

42. **io-witness-borrowing-async-tension.md** v1.0, 2026-04-13.
    `/Users/coen/Developer/swift-foundations/swift-io/Research/
    io-witness-borrowing-async-tension.md`

43. **io-blocking-executor-binding.md** v4.0, 2026-04-14.
    `/Users/coen/Developer/swift-foundations/swift-io/Research/
    io-blocking-executor-binding.md`

44. **perfect-api.md** v3.0, 2026-04-08.
    `/Users/coen/Developer/swift-foundations/swift-io/Research/
    perfect-api.md`

45. **io-vs-nio-comparative-analysis.md** v1.0, 2026-04-16.
    `/Users/coen/Developer/swift-foundations/Research/
    io-vs-nio-comparative-analysis.md`

46. **nio-inspired-capability-additions.md** v1.0, 2026-04-16.
    `/Users/coen/Developer/swift-foundations/Research/
    nio-inspired-capability-additions.md`

47. **io-driver-witness-composition.md** v1.0, 2026-04-13.
    `/Users/coen/Developer/swift-foundations/Research/
    io-driver-witness-composition.md`

48. **io-witness-experiment-results.md** v1.0, 2026-04-13.
    `/Users/coen/Developer/swift-foundations/Research/
    io-witness-experiment-results.md`

49. Each experiment's **EXPERIMENT.md** file at
    `/Users/coen/Developer/swift-primitives/Experiments/io-witness-*/`.

#### Production Libraries (Primary Sources)

50. **Apple swift-nio**: `https://github.com/apple/swift-nio`
    (inspected commit at 2026-04-16).

51. **Tokio**: `https://docs.rs/tokio/latest/tokio/io/` and
    `https://github.com/tokio-rs/tokio`.

52. **monoio**: `https://github.com/bytedance/monoio`.

53. **glommio**: `https://github.com/DataDog/glommio`.

54. **Boost.Asio**:
    `https://www.boost.org/doc/libs/1_88_0/doc/html/boost_asio.html`.

55. **Netty**: `https://netty.io/4.1/api/`.

56. **OCaml Eio**: `https://ocaml-multicore.github.io/eio/`.

57. **ZIO**: `https://zio.dev/` and
    `https://github.com/zio/zio`.

58. **Go net package**: `https://pkg.go.dev/net`.

59. **.NET Stream**:
    `https://learn.microsoft.com/en-us/dotnet/api/system.io.stream`.

60. **Rust std::io**: `https://doc.rust-lang.org/std/io/`.

#### Swift Institute Feedback Memories (cited for specific findings)

61. `feedback_sending_over_sendable_return.md` — "Use `sending R`
    not `R: Sendable` on actor returns; strictly more flexible."

62. `feedback_no_sendable_constraint_workaround.md` — "Fix region
    transfer with Slot, don't add Element: Sendable as workaround."

63. `feedback_isolated_param_for_borrowing_noncopyable.md` —
    "`isolated Actor` parameter for borrowing `~Copyable` across
    actor boundaries; no closure needed."

64. `feedback_continuation_dispatch_pattern.md` —
    "withCheckedContinuation + Task<Void,Never> avoids T: Sendable
    on executor dispatch."

65. `feedback_toolchain_versions.md` — "Only use Swift 6.3 and
    6.4-dev nightly; never test against 6.1 or other versions."

---

## End of Document

---

**Document Metadata**:

- Total length: 2000+ lines.
- Section count: 12 major sections + 7 appendices.
- Table count: 20+ comparative tables across §§5, 7, 10, 11.
- Cited references: 65 primary sources (academic, Swift Evolution,
  production libraries, Swift Institute research, feedback memories).

