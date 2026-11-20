# Phase 63 — Integer and logic-based Benders

Use `IntegerBendersSolver.solve` with a `BendersProblem` to solve a
mixed-integer master with LP or MILP recourse. Set integrality and
finite integer bounds on the corresponding `SparseLinearProblem`
columns. LP recourse can link to any first-stage column. MILP recourse
links through binary first-stage columns. The solver reuses one master
tree and shares lazy cuts across open nodes.

To use a domain solver or combinatorial oracle, register a
`LogicBendersScenario` in an `IntegerBendersProblem`. Declare the binary
master columns it reads and a valid global recourse floor. The Swift
closure runs synchronously on integer candidates.

```swift
let result = try IntegerBendersSolver.solve(problem) { scenario, bits in
    // This example oracle requires the first bit to be enabled.
    guard bits[0] else { return .infeasible(conflict: [0]) }
    return .optimal(objective: 2, validity: [0])
}
```

A conflict rules out every assignment matching the listed bit positions.
An optimal response asserts that the cost is attained at this assignment
and lower-bounds recourse for all assignments matching its validity
scope. Use `nil` for the whole projection and `.unresolved` when the
domain solver lacks proof. The result flags oracle-based bounds and
reports a blocking scenario for unresolved evaluations.

The API activates after the Rust v0.38.0 XCFramework and UniFFI bindings
are synced. Use `IntegerBendersSolver.isAvailable` to detect availability
when supporting older pins.
