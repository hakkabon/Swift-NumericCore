# Phase 37: nonlinear equation systems and continuation

Phase 37 introduces a first-class `F(x) = 0` contract. Equation systems are
not converted to least-squares objectives, so Newton systems retain their
conditioning, sign, and sparse/matrix-free structure.

`NonlinearSystemSolver` provides:

- damped Newton with pivoted dense linear solves;
- configurable variable and residual scaling;
- modified-Newton Jacobian reuse with explicit reuse diagnostics;
- matrix-free inexact Newton with GMRES and `Jv` callbacks;
- Armijo residual-norm globalization;
- observer cancellation and explicit singular, Krylov, line-search, and limit
  terminations;
- adaptive natural-parameter continuation; and
- pseudo-transient continuation using `(J + I/dt) s = -F` for difficult or
  initially singular operating points.

`NonlinearEquationModel` is a square vector of existing
`NonlinearExpression` graphs. It preserves the semantic distinction between
equations and least squares while reusing exact graph Jacobians.

Swift and Rust expose matching native contracts. Callback APIs remain outside
UniFFI; a future value-only equation-model transport can execute the graph
wholly in Rust after its wire schema is stabilized.

## Powell hybrid solver

`NonlinearSystemSolver.solvePowellHybrid` uses a dense scaled dogleg step
with rank-one Jacobian updates between analytic refreshes. Check
`NonlinearSystemSolver.isPowellHybridAvailable` on the linked FFI.

```swift
let result = try NonlinearSystemSolver.solvePowellHybrid(
    initial: [-1.2, 1],
    residual: { x in [10 * (x[1] - x[0] * x[0]), 1 - x[0]] },
    jacobian: { x in [[-20 * x[0], 10], [-1, 0]] }
)
```

You can also pass a `NonlinearEquationModel`. Rust evaluates the graph
without derivatives at trial points and computes an analytic Jacobian
when the solver requests a refresh. The residual budget includes the
initial evaluation. The report counts residual evaluations, analytic
Jacobian evaluations, and rank-one updates separately. The residual
tolerance applies after multiplying by the residual scales. The step
tolerance and trust radius use coordinates in which each component of
the step is multiplied by its variable scale to obtain a physical step.
A small step with residual above tolerance reports `.stalled`.
