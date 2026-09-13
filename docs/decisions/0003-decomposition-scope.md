# 0003 — Matrix decompositions: wrap Accelerate/LAPACKE first, don't reimplement

## Status
Accepted.

## Context
LU, QR, Cholesky, and SVD decompositions are available, well-tested, and
fast in Apple's Accelerate framework (via LAPACK/LAPACKE linkage).
Reimplementing them in `nc-decomp` (Rust) would mean redoing genuinely
hard numerical work — pivoting strategies, rank-deficient and
near-singular edge cases, numerical stability — that LAPACK has decades
of engineering behind.

This was flagged during initial scoping conversation as the
highest-variance item in the whole project: "naive LU/QR is a week; LU
with proper pivoting, SVD with edge-case handling, numerically stable
eigenvalue algorithms — that's where 'I thought this was done'
surprises live."

## Decision
v1 does **not** implement decompositions in `nc-decomp`. Instead,
`NumericCoreAccelerate` wraps Accelerate's LAPACKE-linked routines
directly (`sgetrf`/`dgetrf` for LU, `sgeqrf`/`dgeqrf` for QR, etc.).

`nc-decomp` (Rust) stays a near-empty scaffold — `DecompositionKind`
enum only — until a *specific, concrete* gap shows up that Accelerate
doesn't cover: a portable (non-Accelerate) fallback for a future non-Mac
target, an extended-precision variant, or similar.

## Consequences
- Decomposition support ships far sooner and far more reliably than a
  from-scratch implementation would allow.
- `NumericCore` (pure Swift/Rust fallback, no Accelerate dependency) has
  **no decomposition support at all** until `nc-decomp` grows real
  content. This is an accepted gap for v1 — anyone using `NumericCore`
  without `NumericCoreAccelerate` cannot factorize matrices yet.
- Column-major storage (ADR 0001) is what makes this wrapping
  straightforward — LAPACKE also expects column-major/Fortran-ordered
  input, so no transpose is needed at this boundary either.

## Alternatives considered
- **Implement LU/QR/SVD in Rust from the start**, for portability beyond
  Apple platforms. Rejected for v1: this project's primary target is
  explicitly the Mac platform (per the original scoping conversation);
  portability is a real but secondary goal that shouldn't gate getting a
  correct, fast decomposition story shipped first.

## Update (QR implemented)
`NumericCoreAccelerate/QRSolve.swift` now wraps `dgeqrf_`/`dormqr_`/
`dtrtrs_` directly for QR decomposition and QR-based `solve`/
`leastSquares` — the first concrete consumer being `Swift-DataLens`'s
`LinAlg`/`Regression` seam (QR + square solve is all LOESS needs, per
that project's own scoping). LU and SVD remain unimplemented; revisit
this ADR's "wrap, don't reimplement" stance only if a concrete need for
them shows up, per the same reasoning that applied to QR.

## Update (Cholesky/SPD implemented)
`NumericCoreAccelerate/CholeskySolve.swift` adds `solveSPD(_:_:)` via
`dpotrf_`/`dpotrs_`, for `Swift-DataLens`'s local-likelihood
calculations where the normal-equations matrix is SPD by construction.
Kept as a separate function from `solve(_:_:)`, not a dispatch path
switched on some "is this SPD" check — LAPACK's Cholesky routine
doesn't verify symmetry, only positive-definiteness, so silently
routing arbitrary input through it would be a correctness trap for any
caller that can't guarantee SPD-ness. Callers opt in explicitly.
