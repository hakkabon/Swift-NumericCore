# SQP and constrained nonlinear strengthening

`SequentialQuadraticProgramming` is the second constrained nonlinear method in
NumericCore. It complements rather than replaces `ConstrainedNonlinearSolver`:
the latter uses an augmented-Lagrangian outer loop, while SQP solves a convex
quadratic model of the KKT system at every iteration.

The SQP subproblem uses exact graph gradients and constraint Jacobian rows,
the Phase 11 convex QP solver, shifted nonlinear-constraint bounds, and shifted
parameter bounds. A positive-definite BFGS approximation models Lagrangian
curvature. An exact L1 merit function and Armijo backtracking reject steps that
do not deliver sufficient combined objective and feasibility improvement.

`SQPResult` reports the accepted point, objective and constraint values,
lower/upper/equality multipliers, maximum violation, projected stationarity,
iteration and evaluation counts, accepted/rejected line-search steps, final
merit penalty, last step norm, and a specific termination reason.

`NonlinearModelSolver.minimizeSQP` selects either the native Swift
implementation or the Rust implementation through the value-only nonlinear
FFI. Swift observers remain native-only; synchronous callbacks are still not
sent across the foreign-function boundary.

The current implementation keeps a dense BFGS matrix. Phase 13's sparse and
matrix-free derivative products prepare a later large-scale SQP variant using
Krylov subproblems, sparse quasi-Newton updates, or Hessian-vector products.
