# Phase 20: specialized and mixed-integer nonlinear methods

`NumericCoreOptimization` now provides `MixedIntegerNonlinearProblem` and
`MixedIntegerNonlinearSolver`. Search nodes tighten integer domains and choose
the appropriate continuous method: bounded L-BFGS for unconstrained nodes, or
configurable SQP/augmented-Lagrangian relaxations for constrained nodes. The
same options and result contract execute through native Swift or Rust FFI.

The AMPL nonlinear compiler now preserves variable integrality instead of
rejecting MINLP. Automatic solving selects mixed-integer nonlinear search when
any compiled variable is integer. Results expose search status, node counts,
the incumbent, nonlinear feasibility and stationarity, and whether global
optimality was certified.

No global claim is made in this phase. Continuous nonlinear relaxations are
local and the expression graph has no convexity certificate, so
`globalOptimalityCertified` remains false and gap termination is named
`localGapLimit`. This distinction is part of the public numerical contract.
Convexity analysis, spatial branching, valid under-estimators, and feasibility
restoration are the next steps toward certified global MINLP.
