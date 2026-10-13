# Phase 32: presolve and model transformation

Phase 32 adds a solver-independent, reversible presolve layer for sparse LP and
MILP models. `LinearModelPresolver` operates on `SparseLinearProblem`, so AMPL,
direct Swift callers, and FFI-backed solvers can share the same transformation
without coupling it to a particular algorithm.

The reduction runs deterministic passes that:

- prove infeasibility from row-activity intervals;
- remove empty or redundant rows;
- propagate singleton rows into variable bounds, with integral rounding;
- eliminate fixed variables and shift row bounds;
- preserve the objective constant created by elimination; and
- rebuild a canonical sparse reduced model.

`PresolvedLinearProblem` is the postsolve certificate. It records original
variable and row mappings, fixed values, the objective offset, and reduction
statistics. `restorePoint` and `restoreObjective` lift a reduced solver result
back to the original model. A model reduced to fixed variables is reported as
`solved`; an interval contradiction is reported as `infeasible`; neither case
requires entering a numerical solver.

The Swift and Rust implementations intentionally expose equivalent semantics
and defaults. This phase limits algebraic elimination to linear constraints.
Quadratic substitution, dual/basis reconstruction, coefficient strengthening,
and nonlinear expression rewriting remain explicit follow-on work rather than
being hidden inside this first correctness-oriented pipeline.
