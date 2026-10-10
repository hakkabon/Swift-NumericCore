# Phase 23: matrix-free nonlinear least squares

The Swift and Rust optimization surfaces now share an explicit matrix-free
nonlinear least-squares capability. The solver uses residual evaluations,
`J·v`, and `Jᵀ·v` only. Conjugate gradient applies the damped Gauss–Newton
operator `(Jᵀ W J + λI)` without forming either `J` or `JᵀJ`.

The API supports observation weights, robust IRLS weights, parameter bounds,
and the established Levenberg–Marquardt acceptance policy. Its result nests
the standard nonlinear least-squares result and adds Krylov iteration,
Jacobian-product, and transpose-product counts. `NonlinearModelSolver` exposes
the same entry point for `.swift` and `.rust`, with conformance tests for both.

The dense QR solver remains unchanged and appropriate for small and medium
dense models. The matrix-free path is opt-in for large residual systems or
applications where Jacobian storage dominates. Future work can add operator
preconditioners, adaptive inner tolerances, and trust-region Krylov stopping.
