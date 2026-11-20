# Phase 65 — Nonlinear decomposition

`NonlinearDecompositionSolver` takes a `SparseLinearProblem` master and
one or more `NonlinearRecourseBlock` values. A block expression addresses
the given shared columns first and the block's private variables second.
For example, with `sharedColumns: [3, 0]` and one private variable,
`.parameter(0)` denotes master column 3 and `.parameter(2)` denotes the
private variable.

Use finite variable bounds and positive recourse weights. Objective and
constraint graphs use the shared `NonlinearExpression` representation.
Convex upper sides and concave lower sides are supported. The result returns
the master decision, private decisions, nonlinear feasibility residuals,
and the audited lower bound when available. A recourse limit identifies
the blocking block and preserves solver evidence already obtained.

The provisional `nonlinear-decomposition` capability activates after Swift
receives the matching Rust release through the UniFFI synchronization workflow.
Check `NonlinearDecompositionSolver.isAvailable` before selecting this solver.
