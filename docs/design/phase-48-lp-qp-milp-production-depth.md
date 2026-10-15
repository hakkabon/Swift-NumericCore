# Phase 48 — LP/QP/MILP production depth

Phase 48 consolidates capabilities that previously had to be composed by a caller.

`ProductionLinearSolver` is the audited LP/MILP entry point. It validates and
presolves the sparse original model, automatically selects revised simplex or
branch-and-bound (with explicit interior-point and branch-and-bound overrides),
restores eliminated variables and the objective, then independently recomputes
row, variable, integrality, and objective errors against the original model.
The result records the presolve reduction and whether the reconstructed answer
passes the requested tolerance.

`QuadraticPolisher` improves the final numerical quality of a converged convex
QP. It infers active row and variable bounds, solves their equality-constrained
KKT system with pivoting, and accepts the candidate only when it remains feasible
and does not materially worsen the objective. Failure or a dependent active set
leaves the original solver result intact.

The Rust implementation exposes matching production-linear and QP-polishing
APIs. These APIs deliberately remain above the existing solver kernels: they add
orchestration, reconstruction, and verification without creating a second LP,
MILP, or QP algorithm.
