# Phase 38: production sparse factorization

Phase 38 turns the one-shot sparse direct-solver seam into a reusable
factorization layer. `SparseSymbolicAnalysis` owns the structural pattern and a
deterministic minimum-degree ordering. `SparseLUFactorization` and
`SparseLDLTFactorization` then reuse that analysis for new numerical values
with the same CSR pattern.

Both factors support multiple right-hand sides and iterative refinement.
Reports expose fill, symbolic fill estimates, pivot quality, growth, swaps,
residuals, and normwise backward error. LDLT accepts symmetric-indefinite
systems, uses 1-by-1 and 2-by-2 pivots, and reports inertia for KKT-based
optimization methods.

The Swift implementation is native in this release. Rust-NumericCore contains
the matching domain API, but it is deliberately not added to UniFFI yet. This
keeps the Rust release and generated Swift binding update atomic; a later FFI
phase can expose persistent factor handles without creating a transient binary
and generated-source mismatch.

Numerical refactorization is transactional: a failed replacement leaves the
existing factor usable. A changed sparsity pattern is rejected and requires a
new symbolic analysis.
