# Sparse and matrix-free derivatives

Phase 13 extends the shared nonlinear graph with scalable first-order
derivatives on both Swift and Rust backends.

`NonlinearExpression.evaluateSparse` performs a primal graph evaluation and a
reverse accumulation, returning a sorted coordinate gradient with structural
zeros omitted. `NonlinearModel.evaluateSparseResiduals` combines those rows in
a `SparseJacobian` using CSR storage. The representation provides direct `Jv`
and `Jᵀv` multiplication for callers that do want to retain the Jacobian.

For large models, `jacobianVectorProduct` evaluates directional derivatives by
forward mode without forming individual gradients. The transpose product uses
one reverse sweep per residual and accumulates directly into parameter space;
it does not assemble the full Jacobian. The same operations are available via
`NonlinearModelSolver` with either `.swift` or `.rust`, and the Rust forms cross
the Phase 12 value-only UniFFI model boundary.

The dense derivative and existing nonlinear solver APIs remain source
compatible. Phase 13 deliberately stopped at first-order primitives: current
L-BFGS, Levenberg-Marquardt, and augmented-Lagrangian implementations are not
silently changed to iterative linear algebra. These products establish the
contract for future matrix-free Gauss-Newton/Krylov and constrained methods.
Phase 22 adds exact Hessians, Hessian-vector products, and sparse KKT solves on
the same shared graph.

The generated Swift bindings and `NumericCoreFFI` binary remain a lockstep
artifact. The Rust release containing these exports must be tagged before the
Swift package can pin its matching framework URL, checksum, and binding file.
