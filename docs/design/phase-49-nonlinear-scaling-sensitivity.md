# Phase 49 — Nonlinear scaling and sensitivity

Phase 49 adds a solver-independent analysis layer above the shared nonlinear
graph and constrained solver results.

`NonlinearSensitivityAnalyzer` identifies the active nonlinear and variable
bounds at a solution, evaluates the exact Lagrangian Hessian, and constructs the
implicit-function KKT system. Variable factors may be supplied explicitly or
derived from the point and finite bound widths. Active rows are then equilibrated
in those coordinates before the pivoted solve.

The sensitivity request describes infinitesimal perturbations to the objective
gradient, nonlinear constraint bounds, and variable bounds. The result returns
the corresponding primal and multiplier derivatives in the original units,
together with active-set metadata, unscaled and scaled Jacobian norm ranges,
the KKT pivot ratio, and the solve residual.

The analysis assumes the reported active set remains unchanged and the
regularized KKT matrix is nonsingular. It therefore describes local sensitivity,
not finite changes across active-set transitions. Singular systems fail
explicitly rather than returning unreliable derivatives.
