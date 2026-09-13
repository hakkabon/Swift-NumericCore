# 0006 — v1 storage is a plain Swift `[Scalar]`, not an `NCBindings`-backed buffer

## Status
Accepted.

## Context
`Matrix<T>`/`Vector<T>` and `SparseMatrix<T>` need backing storage. Two
options: a plain Swift `[Scalar]` array, or a buffer type backed by
memory shared with the Rust side across the FFI boundary (avoiding a
copy when a Rust kernel operates on Swift-allocated data, or vice
versa).

A shared-memory buffer is a real future optimization — it removes a
copy on every FFI call — but designing it correctly (ownership,
lifetime, mutability-across-languages, alignment) is nontrivial, and
`nc-ffi` has no real exports yet (ADR 0005 covers the FFI approach, but
implementation hasn't started).

## Decision
v1 storage for `Matrix<T>`, `Vector<T>`, and `SparseMatrix<T>` is a
plain Swift `[Scalar]` (or three parallel arrays, for CSR). All v1
operations (`RustFallbackBackend`, `SparseMatrix.multiplying`,
`GraphBridge.adjacencyMatrix`) are implemented directly in Swift,
mirroring the equivalent Rust algorithm rather than calling through to
it.

This means today's `RustFallbackBackend` doesn't actually call into
Rust at all, despite the name — it exists to fix the `Backend` protocol
shape and prove `Dispatcher`/`DispatchPolicy` work end-to-end, and is
expected to be rewired to call through `NCBindings` once real UniFFI
exports exist, at which point the shared-memory-buffer question gets
revisited for real.

## Consequences
- `NumericCore` is immediately usable — correct, if unoptimized — the
  moment the Swift package builds, without waiting for `nc-ffi` to be
  finished.
- There is real duplicated logic between `nc-kernels-generic` (Rust) and
  `RustFallbackBackend` (Swift) today. This is accepted debt: when
  `NCBindings` gets real bindings, `RustFallbackBackend`'s method bodies
  should be replaced with calls through, not maintained as a second
  parallel implementation indefinitely.
- Every operation currently pays a full array copy on each call
  (`Matrix` is a value type; Swift's copy-on-write means this is cheaper
  than it sounds, but it's not the zero-copy path the architecture
  ultimately wants).

## Alternatives considered
- **Design the shared-memory buffer now, before any real UniFFI export
  exists.** Rejected: high risk of designing it against an imagined FFI
  shape rather than the real one, and blocks all other v1 work on
  getting this one hard problem right first.

## Update (Double path retired, Float remains)
`RustFallbackBackend` and `SparseMatrix.multiplying` now call through
`NCBindings.FFIKernels` (backed by `nc-ffi`'s real UniFFI exports — see
ADR 0005's update and ADR 0009) for `Scalar == Double`. The duplication
called out above is retired for that case: `Double` matmul/axpy/dot/norm
and CSR SpMV now run the actual Rust implementation, not a second
Swift copy of it.

`Float` still runs the original pure-Swift loops (`SwiftFallbackKernels`
in `RustFallbackBackend.swift`), because `nc-ffi` has no `f32` exports
yet (deliberately deferred — see that crate's module docs). The
duplication this ADR flagged as debt is now half-retired, not fully:
revisit once/if `f32` FFI exports are added, following the exact same
pattern already established for `f64`.

Storage itself (`[Scalar]`, not a shared-memory buffer) is unchanged —
this update only addresses which implementation runs on top of that
storage, not the storage model itself. Every FFI call still pays a full
array copy in each direction (see `nc-ffi`'s own module docs on why);
that remains the next real optimization opportunity if profiling ever
shows it matters.

## Update (Float retired too — duplication fully gone)
`nc-ffi` gained `f32` counterparts of every export
(`matmul_f32`/`dot_f32`/`axpy_f32`/`norm2_f32`/`spmv_f32`), and
`RustFallbackBackend`/`SparseMatrix` were rewired to use them.
`SwiftFallbackKernels` — the pure-Swift naive loops mentioned above —
is deleted; there is no Swift-side numeric implementation left in
either file. Every `NCScalar` conformance (`Float` and `Double`, the
only two that exist) now runs the actual Rust kernels for
matmul/axpy/dot/norm/SpMV. The storage-model caveat two paragraphs up
still stands unchanged: this was about which implementation runs, not
about the array-copy-per-call cost, which remains the next real
optimization target if it's ever measured to matter.
