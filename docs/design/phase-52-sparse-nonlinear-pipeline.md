# Phase 52 — Sparse nonlinear solver pipeline

Phase 52 makes the native Swift KKT path genuinely sparse. The earlier API
accepted sparse Hessian and Jacobian inputs but materialized a dense saddle-
point matrix. It now assembles canonical sparse storage and solves through the
reusable symmetric-indefinite LDLᵀ factorization in `NumericCoreSparse`.

`SparseKKTWorkspace` retains minimum-degree symbolic analysis across changing
numeric values, refactorizes without reanalysis, applies iterative refinement,
and returns residual, fill, reuse, solve-count, and inertia diagnostics. A
changed sparsity pattern is rejected explicitly. `SparseKKTSolver.solve`
remains the source-compatible one-shot wrapper, and the Rust/UniFFI backend
continues to conform to the same solution contract.

`ConstrainedNonlinearProblem.linearizeSparseKKT` lowers exact Lagrangian
Hessians and reverse-mode sparse constraint Jacobians from the shared nonlinear
graph into the workspace contract. This is the common sparse Newton-system seam
for SQP, nonlinear interior point, sensitivity analysis, circuits, and FEM.

The standard Phase 51 corpus now release-gates symbolic reuse across two
numerical factorizations, refined residual quality, and the expected
saddle-point inertia. Larger external sparse NLP cases, multifrontal
factorization, and matrix-free preconditioned KKT solves remain later work.
