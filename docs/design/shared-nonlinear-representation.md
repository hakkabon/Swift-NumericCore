# Shared nonlinear representation

`NonlinearExpression` and `NonlinearModel` provide the canonical portable seam
between model construction and nonlinear solvers.

An expression is a flat, topologically ordered graph. Its nodes cover finite
constants, indexed parameters, arithmetic, negation, exponential, logarithm,
square root, sine, cosine, and constant powers. Evaluating the graph propagates
exact first derivatives, yielding either a scalar objective and gradient or a
residual vector and row-major Jacobian.

A model carries a fixed parameter count, one bound per parameter, and exactly
one of a scalar objective or non-empty residual vector. Validation rejects
forward graph references, invalid parameter indices, malformed bounds, mixed
objective/residual models, and non-finite graph metadata. Numerical domain
errors fail as invalid evaluations.

The shared model can be passed directly to `LBFGS.minimize(model:...)`,
`LBFGSB.minimize(model:...)`, or `NonlinearLeastSquares.solve(model:...)`.
Existing callback APIs remain the preferred escape hatch for opaque or highly
specialized code. The flat graph deliberately matches Rust's representation so
a later FFI or modeling-language layer does not need to translate recursive
language-specific expression trees.
