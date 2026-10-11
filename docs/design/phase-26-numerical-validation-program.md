# Phase 26: numerical validation program

Phase 26 turns numerical correctness from scattered assertions into a shared,
repeatable program. `NumericCore` now defines mixed absolute/relative
tolerances, named metrics, cases and aggregate reports, independent linear
system backward-error checks, and seeded perturbations for sensitivity tests.
Invalid or non-finite observations fail closed.

`NumericCoreValidationProgram` exercises four hand-checkable production paths:

- LP reference values and scaling invariance;
- convex QP feasibility and stationarity from a deliberately poor initial
  ADMM penalty;
- an enumerated MILP optimum, integrality and zero certified gap; and
- the same portable nonlinear model on Swift and Rust backends.

The cases are deliberately small enough to audit. They complement larger unit
tests; they are not a benchmark suite and do not substitute for external
collections such as Netlib, Mittelmann, CUTEst, or MIPLIB. Pull-request CI now
runs the complete Swift test suite so regressions are caught before release.
