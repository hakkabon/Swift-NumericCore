# Phase 19: nonlinear interior point

`NumericCoreOptimization` now exposes a feasible-start nonlinear
interior-point method over `ConstrainedNonlinearProblem`. Log barriers enforce
nonlinear inequalities and parameter bounds, equality constraints use an
augmented multiplier update, and inverse BFGS supplies curvature without
requiring second derivatives in the shared expression graph.

`NonlinearModelSolver.minimizeInteriorPoint` has the same result and options
contract for `.swift` and `.rust`. Results include constraint multipliers,
maximum primal violation, stationarity, complementarity, barrier state, work
counters, and an explicit termination reason. Cross-backend tests cover active
inequalities, equality constraints from an infeasible equality start, and
rejection of non-strict inequality starts.

The initial point must lie strictly inside every inequality and finite
variable bound. Equalities need not be feasible. This is intentional: Phase 19
does not disguise restoration as projection, and `infeasibleStart` tells a
caller when a Phase-I strategy is required.

Future depth should add a feasibility-restoration phase, filter line search,
sparse KKT systems using the existing sparse direct/preconditioned layer,
Hessian-vector or limited-memory operators, and reusable primal-dual warm
starts.
