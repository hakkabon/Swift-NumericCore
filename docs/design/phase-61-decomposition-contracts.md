# Phase 61 — Decomposition-ready solver contracts

`LPReoptimizationWorkspace` holds a Rust simplex workspace for a continuous
`SparseLinearProblem`. Associate an `LPSubproblemID` with each scenario if
its reports need attribution.

```swift
let workspace = try LPReoptimizationWorkspace(
    problem: recourse, subproblem: .init(name: "recourse", scenario: "winter"))
let initial = try workspace.solve()
try workspace.update(.init(rowBounds: [.init(index: 0, bound: .init(lower: 4))]))
let next = try workspace.solve()
```

Reports expose basis statuses, pricing iterations, pivots and whether the
workspace reused a basis. Edits can update the objective, variable bounds,
or row bounds, and append rows and columns. New rows address existing
columns. New columns can also address newly appended rows.

Row duals use minimization signs, with positive multipliers selecting lower
bounds. Optimal, infeasible, and unbounded statuses may carry verified
dual, Farkas, and improving-ray evidence respectively. Require the
corresponding evidence when deriving a cut. The `LPDecompositionEvidence`
functions verify external candidates on the original model. The
`PresolvedLinearProblem` lifts may return `nil` when elimination or bound
tightening prevents recovering verified evidence.

`QuadraticWorkspace` is Swift-native and reuses its initial factor and
converged primal and dual values across linear-cost and bound edits for a
fixed Hessian and constraint matrix. Decomposition cut pooling lives with
the Rust coordination APIs.

## FFI rollout

Publish Rust v0.36.0 and sync the matching XCFramework and generated
bindings through the existing FFI workflow. Swift enables the workspace
when those generated bindings arrive and reports the provisional
`lp-decomposition` capability. Earlier pins keep their existing solvers
and return `LPDecompositionError.unsupportedFFI` from the new LP entry
points. `LPReoptimizationWorkspace.isAvailable` can be checked before use.
