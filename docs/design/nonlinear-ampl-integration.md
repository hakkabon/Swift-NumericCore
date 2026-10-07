# Nonlinear AMPL integration

Phase 15 extends the existing unindexed AMPL subset with scalar nonlinear
expressions while preserving the LP/MILP compiler. The parser produces an
`AlgebraicExpression` tree with precedence-aware arithmetic, parentheses,
constant powers, and `exp`, `log`, `sqrt`, `sin`, and `cos` functions.
Parameters are folded into constants and variables retain source-model order.

Every parsed algebraic expression attempts an affine projection. Affine models
continue through `Model.compile()` and the established LP/MILP path without a
second parser or compatibility mode. A genuinely nonlinear expression causes
the linear compiler to fail explicitly; `Model.compileNonlinear()` instead
lowers the tree into the shared `NonlinearExpression` graph.

`CompiledNonlinearProblem.solve` supports automatic method selection, bounded
L-BFGS for unconstrained models, SQP for constrained models, and the
augmented-Lagrangian solver as an explicit alternative. Each method can use the
native Swift or Rust backend. Objective sense is normalized internally and
restored in `NonlinearAMPLSolution`, whose diagnostics include named variables
and constraints, multipliers, maximum violation, and stationarity.

Mixed-integer nonlinear programming is deliberately rejected rather than
relaxed silently. Indexed expressions, sets, sums, user-defined functions,
nonsmooth operators, and initial-value syntax remain outside this phase.
