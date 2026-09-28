# Numerical contracts and independent verification

NumericCore distinguishes three kinds of outcome:

1. invalid structure or backend failure — thrown as an error;
2. a valid problem with a negative numerical verdict — represented by a
   termination value such as `rankDeficient` or `notPositiveDefinite`;
3. a computed solution — accompanied by independently recomputed diagnostics.

The original optional-return APIs remain source-compatible. New code that needs
to explain or audit a result should use `solveReport`, `leastSquaresReport`,
`solveLUReport`, or `solveSPDReport`.

## Tolerances

`NumericalTolerance` combines absolute and relative components. Decisions use

```text
max(absolute, relative × scale × dimension)
```

The default is relative to machine precision, the observed factorization scale,
and problem dimension. An explicitly absolute policy remains available when a
consumer must reproduce a legacy threshold.

## Linear solves

`LinearSolveReport` records the termination reason, solution when accepted,
backward residual, estimated rank where available, and the actual decision
threshold. Residuals are recomputed from the original matrix, response, and
returned solution rather than LAPACK's overwritten factorization buffers.

## Optimization

Every Swift `LPSolution` carries `OptimizationSolutionDiagnostics`, recomputed
from `CompiledProblem`. It reports row feasibility, variable-bound feasibility,
integrality, and objective agreement. This deliberately exposes the distinction
between solving a mixed-integer model with `.simplex` (a valid LP relaxation
that can violate integrality) and `.branchAndBound` (a verified integer result).

Rust provides the matching `Solution::diagnostics` and
`Solver::solve_with_diagnostics` APIs without changing the existing FFI ABI.

## Compatibility

The richer APIs are additive. Existing `nil`-returning dense solve methods and
the existing FFI records retain their behavior. This lets downstream projects
adopt diagnostics deliberately instead of requiring a flag-day migration.

