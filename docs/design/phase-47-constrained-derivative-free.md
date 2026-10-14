# Phase 47: constrained derivative-free optimization

`ConstrainedDerivativeFree` evaluates an objective and all black-box
constraints in one callback. Inequalities use `c(x) <= 0`; equalities use
`h(x) = 0`. Coordinate interpolation builds local affine models for the
objective and every constraint from the same simulation samples.

The trust-region subproblem minimizes an adaptive exact-penalty model inside
the parameter box. It prioritizes feasibility from infeasible starts and uses
projected tangential objective steps near the active constraint manifold.
Actual and predicted merit reductions control step acceptance and radius
updates, while inadequate feasibility progress increases the penalty.

Results expose constraint values, maximum and aggregate violation, model and
evaluation counts, accepted and feasibility-improving steps, penalty updates,
final radius, and reduction ratio. A small radius is reported as `converged`
only when feasible; otherwise termination is `infeasibleStationary`.

The method is COBYLA-inspired but is not claimed to reproduce COBYLA. A future
implementation may maintain a general poised simplex, solve the linearized
trust-region subproblem more exactly, and add filter-based constraint handling.
