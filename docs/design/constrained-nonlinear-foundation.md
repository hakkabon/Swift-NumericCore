# Constrained nonlinear foundation

`NonlinearConstraint` adds smooth equality, inequality, and range constraints
to the Phase 9 expression graph through one uniform contract:

```text
lower <= expression(parameters) <= upper
```

`ConstrainedNonlinearProblem` requires a scalar objective model and one or more
constraints. It validates expression topology, dimensions, and finite ordered
bounds before solving.

`ConstrainedNonlinearSolver` uses a Powell–Hestenes–Rockafellar augmented
Lagrangian outer method and the existing projected L-BFGS implementation for
its box-constrained inner problems. It maintains separate non-negative lower
and upper multipliers and a signed equality multiplier. Convergence requires
both primal feasibility and projected Lagrangian stationarity.

Results expose the original objective and constraint values, multipliers,
maximum violation, stationarity norm, iteration and evaluation telemetry,
penalty state, and explicit convergence, limit, or cancellation termination.

This phase establishes the representation and correctness diagnostics needed
by future SQP or nonlinear interior-point methods. It does not yet include
second derivatives, feasibility restoration, filter globalization, or LICQ
and active-Jacobian rank diagnostics.
