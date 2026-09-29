# Bounded and robust nonlinear optimization

Phase 8 adds two matching vertical capabilities to the Swift and Rust layers.

`LBFGSB.minimize` handles independent parameter bounds. It projects the initial
point and line-search trials, suppresses directions that leave active bounds,
updates curvature with the actual feasible displacement, and reports the
projected-gradient norm. This is a projected limited-memory method with a
projected Armijo search; it does not claim the full generalized-Cauchy-point
and subspace machinery of the original Fortran L-BFGS-B implementation.

The configured `NonlinearLeastSquares.solve` overload combines bounds,
non-negative observation weights, and squared, Huber, or Cauchy loss. Its
Levenberg–Marquardt step uses the corresponding IRLS linearization, while the
gain ratio and stopping decisions use the true robust objective. Empty weights
mean unit weights; zero-weight observations remain dimensionally present but
do not influence the fit.

Rust mirrors this contract with `minimize_lbfgsb`, `Bound`, `RobustLoss`, and
`nonlinear_least_squares_configured`.
