# Phase 25: LP/QP/MILP production depth

Phase 25 is a coordinated production-hardening pass across the native Rust
solvers and the Swift-facing optimization APIs.

- Revised simplex periodically rebuilds its explicit basis inverse from the
  current basis, limiting accumulated pivot-update roundoff on longer runs.
- The Swift and Rust convex QP solvers use the same residual-balanced ADMM
  penalty policy. Penalty changes preserve the unscaled dual estimate and
  rebuild the system factorization.
- MILP branch-and-bound tries a nearest-integer incumbent at fractional LP
  nodes. Every candidate is independently checked before acceptance.

`BranchAndBoundSolveOptions.roundingHeuristic` and its FFI counterpart control
the MILP heuristic. `MILPSearchReport` exposes attempt and success counts, so
callers can measure its effect without inferring behavior from node counts.

The phase deliberately preserves existing solver scope: simplex remains dense,
QP remains convex ADMM, and MILP does not yet include a cut pool, presolve
pipeline, or advanced primal heuristics.
