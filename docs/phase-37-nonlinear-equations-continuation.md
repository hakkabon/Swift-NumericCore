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
