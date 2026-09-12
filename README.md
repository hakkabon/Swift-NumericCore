# Swift-NumericCore

A numerical computing platform for Apple platforms — `Matrix<T>`/
`Vector<T>` with a capability-based dispatcher across Accelerate, Metal
Performance Shaders, and a pure-Swift fallback — plus an AMPL-style
declarative modeling language and solver interface built on top.

This is the Swift half of the project. The Rust half
(kernels/sparse/solvers, consumed via UniFFI) lives in
[`Rust-NumericCore`](https://github.com/hakkabon/Rust-NumericCore) — see
`docs/decisions/0008-split-into-two-repos.md` for why they're split, and
importantly: **this package currently has no build-time dependency on
Rust-NumericCore at all** (see that ADR and 0006). It builds and works
standalone via Swift Package Manager.

**Not related to Apple's `swift-numerics`.** The similar name is a
known, deliberately-avoided near-collision — see ADR 0008.

## Adding as a dependency

```swift
dependencies: [
    .package(url: "https://github.com/hakkabon/Swift-NumericCore", branch: "main"),
]
```

then depend on whichever product(s) you need — `NumericCore` is the
core `Matrix`/`Vector`/`Dispatcher` API; `NumericCoreAccelerate`,
`NumericCoreSparse`, `NumericCoreGraph`, `NumericCoreAMPL` are additive.

## Package layout

```
Swift-NumericCore/
├── Sources/
│   ├── NCBindings/            # raw UniFFI wrapper — not public API, currently near-empty
│   ├── NumericCore/           # Matrix<T>, Vector<T>, Backend, DispatchPolicy, Dispatcher
│   ├── NumericCoreAccelerate/ # Accelerate backend — matmul implemented via cblas_dgemm/sgemm
│   ├── NumericCoreMPS/        # Metal Performance Shaders backend (scaffold)
│   ├── NumericCoreSparse/     # SparseMatrix<T> (CSR), SpMV
│   ├── NumericCoreGraph/      # bridge to NetworkGraph/Layout — adjacency matrices
│   └── NumericCoreAMPL/       # AMPL-style modeling language (Model only, so far)
├── Tests/
└── docs/
    ├── decisions/             # full ADR set for the NumericCore project
    └── design/                # AMPL grammar sketch, dispatch-threshold tuning notes
```

## What's actually implemented

- `NumericCore` — `Matrix<T>`, `Vector<T>` (column-major, `Float`/`Double`
  only, with a row-major `init(rows: [[Scalar]])`/`.rowMajorArray`
  convenience for callers working with nested arrays), `Backend`
  protocol, `DispatchPolicy`, `Dispatcher`, and a real (if unoptimized)
  `RustFallbackBackend` implementing matmul/axpy/dot/norm directly in
  Swift.
- `NumericCoreAccelerate` — `matmul`, `axpy`, `dot`, and `norm` (L2 only)
  are all real now, via `cblas_dgemm`/`sgemm`, `cblas_daxpy`/`saxpy`,
  `cblas_ddot`/`sdot`, and `cblas_dnrm2`/`snrm2`. `capabilities` now
  advertises `.matmul`, `.elementwise`, and `.reduction`, so `Dispatcher`
  actually routes to this backend for all of them when registered.
  `QRSolve.swift` adds QR decomposition and QR-based `solve`/
  `leastSquares` (`Double` only, called directly rather than through
  `Dispatcher` — see ADR 0003) — **written without a Swift compiler
  available; build the test suite before trusting either file.** See
  `docs/design/datalens-integration.md` for how this maps onto
  `Swift-DataLens`'s `LinAlg`/`Regression` seam.
- `NumericCoreSparse` — `SparseMatrix<T>` (CSR), real SpMV.
- `NumericCoreGraph` — adjacency-matrix construction from an edge list.
- `NumericCoreMPS` — empty scaffold (`capabilities = []`).
- `NumericCoreAMPL` — only `Model` (variable declaration) exists; the
  parser, presolve, and solver call-through are unbuilt. See
  `docs/design/ampl-grammar.md` for the planned grammar and pipeline.

Confirmed building on a real Mac toolchain as of the last full review;
anything added after that point in a given conversation may not be
re-verified — check the most recent commit message / PR description for
what's been built-and-tested versus written-but-unverified.

## Building

```bash
swift build
swift test
```

## Design principles

1. Don't reinvent Accelerate — wrap it; write fallback kernels only for
   what it doesn't cover.
2. Capability-based dispatch (`DispatchPolicy` asks "who can do X", not
   "is this Accelerate") so adding a backend is additive.
3. Don't build ahead of a concrete need — several modules are
   intentionally minimal scaffolds with a documented reason, not
   speculative implementations.
4. `Matrix`/`Vector` never see a backend directly — always through
   `Dispatcher`.
5. Every deferred decision is written down in `docs/decisions/`, not
   just skipped.

## Related projects

- [`Rust-NumericCore`](https://github.com/hakkabon/Rust-NumericCore) —
  the Rust workspace this package will eventually call through to via
  UniFFI.
- [`Swift-DataLens`](https://github.com/hakkabon/Swift-DataLens) — a
  LOESS/LOCFIT local regression implementation and the first external
  consumer of this package; its `LinAlg`/`Regression` least-squares
  seam is a natural future integration point once `NumericCore.Matrix`
  covers QR-based least squares.
