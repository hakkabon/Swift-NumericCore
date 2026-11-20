# Phase 66 — Production sparse solver expansion

`SparseFactorizationPlan` analyzes the CSR pattern and exposes the ordering,
permutations, and a structural fill estimate. Call `factor(matrix:method:options:)`
to get a persistent Rust-backed `SparseFactorizationWorkspace`. Choose LU for
general square systems, Cholesky for symmetric positive definite systems, or
LDLᵀ for symmetric indefinite systems such as KKT matrices.

For repeated right-hand sides, call `solve` or `solveRefined` with a batch.
Use `orientation: .transpose` for an adjoint solve. Use
`refactor(values:)` when the values change in the same CSR storage order or
`refactor(with:)` to validate a full replacement matrix. A failed refactor
leaves the previous factor usable. `status()` reports factor diagnostics
and, for LDLᵀ, inertia. Refined solve reports include backward error
against the original matrix in the requested orientation.

The provisional `sparse-solver-workspaces` capability becomes available when
the release sync installs the matching Rust binary and generated bindings.
Query `SparseFactorizationPlan.isAvailable` before selecting this API.
