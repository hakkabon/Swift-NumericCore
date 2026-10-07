# Convex quadratic programming

`QuadraticProblem` mirrors Rust's Phase 11 continuous-QP contract:

```text
minimize    0.5 x' Q x + c' x + constant
subject to  rowLower <= A x <= rowUpper
            varLower <= x   <= varUpper
```

The Hessian is dense. Linear constraints use a small read-only CSR transport
type so the public optimization module does not depend on the FFI-backed sparse
module. Validation checks dimensions, finite coefficients, ordered finite
bounds, symmetry, and positive semidefiniteness.

`ConvexQuadraticSolver` is an OSQP-style ADMM foundation. It factors the
constant positive-definite system once, projects all row and variable bounds in
one step, supports primal/dual warm starts and cancellation, and reports the
original objective, activities, dual estimates, ADMM residuals, KKT
stationarity, and independent feasibility diagnostics.

Swift and Rust intentionally share semantics and conformance cases. A later
FFI phase can make Rust authoritative without changing the Swift-facing model.
Adaptive penalty selection, scaling, polishing, sparse factorization, and
infeasibility certificates remain future strengthening work.
