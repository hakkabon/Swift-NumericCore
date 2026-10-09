# Phase 21: feasibility restoration and filter globalization

`NumericCoreOptimization` now exposes `FeasibilityRestoration` and the unified
`NonlinearModelSolver.restoreFeasibility` entry point. The Phase-I objective is
the squared equality and active inequality violation. Variable bounds are
handled by projected L-BFGS, and an interior margin can request the strict
inequality point needed by the nonlinear barrier method.

`SQPOptions` adds an opt-in restoration stage and `.filter` globalization. The
filter retains non-dominated feasibility/objective pairs, while feasible
iterates continue to use the established merit sufficient-decrease test.
`NonlinearInteriorPointOptions` can now restore a boundary or infeasible start
before beginning its barrier sequence. Both methods report restoration failure
as a distinct termination instead of disguising it as line-search failure or
infeasibility.

The feature is implemented natively in Swift and Rust and transported through
the value-only UniFFI graph boundary. Existing defaults preserve the Phase 19
and Phase 14 behavior: restoration is disabled and SQP uses merit
globalization until callers opt into Phase 21.

Restoration convergence is a local numerical result, not an infeasibility
certificate. Later phases can add explicit elastic variables, trust-region
restoration, and sparse second-order KKT systems.
