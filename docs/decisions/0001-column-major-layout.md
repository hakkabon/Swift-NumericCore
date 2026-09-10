# 0001 — Column-major storage for `Matrix<T>`

## Status
Accepted.

## Context
Dense matrix storage needs one canonical memory order. The two options
are row-major (C/most languages' native 2D-array convention) and
column-major (Fortran's convention).

`NumericCoreAccelerate` wraps Apple's Accelerate framework, which wraps
BLAS/LAPACK — both of which are Fortran-heritage APIs and expect
column-major input. If `Matrix<T>` stored row-major, every call into
Accelerate would need either:
- an explicit transpose before/after the call (real cost, real bugs), or
- lying about the leading-dimension parameter and effectively computing
  `Aᵀ` instead of `A` (works for some operations, silently wrong for
  others — a correctness trap).

## Decision
`Matrix<T>` stores elements column-major: `storage[i + j * rows]` is
element `(i, j)`.

`nc-core::Layout` (Rust side) supports both orders generically (`Order`
enum) since `nc-core` is not Accelerate-specific and may back other
consumers later, but the Swift-facing `Matrix<T>` type fixes
column-major as its only order in v1 rather than exposing order as a
parameter — see "Alternatives considered."

## Consequences
- Zero-copy interop with Accelerate/BLAS/LAPACK calls.
- Iterating "by column" is the cache-friendly access pattern; iterating
  "by row" is not. Document this on any method that iterates.
- Anyone porting row-major-authored numeric code (many textbook
  algorithms are written assuming row-major) needs to either transpose
  their mental model or transpose the matrix once at construction.

## Alternatives considered
- **Row-major, transpose at the Accelerate boundary.** Rejected: pays
  the transpose cost on every Accelerate call, which is the hot path
  this whole project exists to make fast.
- **Order as a generic parameter on `Matrix<T, Order>`.** Rejected for
  v1: real flexibility, but adds real API complexity (every function
  signature grows a second generic parameter) before there's a concrete
  need for row-major storage anywhere in this codebase. Revisit if a
  future backend (e.g. a row-major-native GPU API) makes a strong case.
