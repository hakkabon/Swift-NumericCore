# Phase 22: second-order derivatives and sparse KKT systems

The shared nonlinear graph now provides exact value/gradient/Hessian
evaluation, Hessian-vector products, sparse CSR Hessians, and weighted
Lagrangian Hessian products on both Swift and Rust backends. The contract is
available through `NonlinearModelSolver`, so callers can compare derivatives
across implementations without callbacks crossing UniFFI.

`SparseKKTProblem` represents a regularized symmetric saddle-point system from
sparse Hessian and Jacobian inputs. The Rust backend uses pivoted sparse LU and
reports residual and fill diagnostics. Native Swift supplies a pivoted dense
reference solve over the same sparse input contract for conformance and small
problems; it does not claim to be the scalable implementation.

SQP adds `.exactLagrangian` curvature as an explicit alternative to `.bfgs`.
Existing behavior remains unchanged by default.

This phase establishes the second-order and KKT seam. Exact Hessian generation
still materializes dense intermediate matrices before CSR filtering, and the
KKT path does not yet provide fill-reducing ordering, symbolic factor reuse,
inertia correction, or Krylov/block-preconditioned solves.
