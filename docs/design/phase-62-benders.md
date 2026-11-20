# Phase 62 — Classical Benders and L-shaped decomposition

`BendersSolver.solve` accepts a `BendersProblem` with a continuous
first-stage LP and one or more independent recourse LPs. Use the
single-recourse initializer for classical Benders. Use `BendersScenario`
values with distinct IDs and positive probabilities that sum to one
for L-shaped decomposition.

Each scenario's recourse problem contains W and the unshifted row bounds
in `l ≤ W y + T x ≤ u`. Its separate CSR coupling matrix holds T, with
one column per first-stage variable. The objective is first-stage cost
plus the probability-weighted recourse costs.

```swift
let result = try BendersSolver.solve(
    .init(firstStage: firstStage, scenarios: scenarios),
    options: .init(cutStrategy: .multi, scenarioThreads: 4))

if result.termination == .converged {
    let plan = result.incumbent
    // Use plan?.firstStage and the scenario recourse decisions.
}
```

The solver retains LP bases across scenario RHS updates. Reports include the
incumbent, numerical lower and upper bounds, gaps, and per-iteration cut
counts. Single-cut mode aggregates the scenario optimality cuts. Multi-cut
mode keeps one epigraph per scenario. Optional trust-region trials and cut
aging can be enabled through `BendersOptions`. Scenario outputs remain
in input order with parallel evaluation.

The supported models have continuous variables and a finite lower bound on
each scenario's attainable recourse cost over the first-stage set. Bounds
and cuts require numerical LP evidence. Check the termination reason before
interpreting an incumbent or an unbounded master relaxation.

The provisional `benders-decomposition` capability activates after the
Rust v0.37.0 release and matching UniFFI sync. Check
`BendersSolver.isAvailable` if your application also runs against earlier
pins. Older pins return `LPDecompositionError.unsupportedFFI`.
