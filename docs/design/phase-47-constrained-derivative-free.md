# Phase 47: constrained derivative-free optimization

`ConstrainedDerivativeFree` evaluates an objective and all black-box
constraints in one callback. Inequalities use `c(x) <= 0`; equalities use
`h(x) = 0`. Coordinate interpolation builds local affine models for the
objective and every constraint from the same simulation samples.

The trust-region subproblem minimizes an adaptive exact-penalty model inside
the parameter box. It prioritizes feasibility from infeasible starts and uses
projected tangential objective steps near the active constraint manifold.
Actual and predicted merit reductions control step acceptance and radius
updates, while inadequate feasibility progress increases the penalty.

Results expose constraint values, maximum and aggregate violation, model and
evaluation counts, accepted and feasibility-improving steps, penalty updates,
final radius, and reduction ratio. A small radius is reported as `converged`
only when feasible; otherwise termination is `infeasibleStationary`.

The method is COBYLA-inspired but is not claimed to reproduce COBYLA. A future
implementation may maintain a general poised simplex, solve the linearized
trust-region subproblem more exactly, and add filter-based constraint handling.

## Powell COBYLA

`CobylaSolver` exposes the PRIMA-based COBYLA implementation through the
Rust FFI. It uses the same combined evaluation type as
`ConstrainedDerivativeFree`. Check `CobylaSolver.isAvailable` for capability
support on the linked release.

```swift
let result = try CobylaSolver.minimize(
    initial: [0, 2],
    constraintKinds: [.lessEqual],
    options: .init(maxEvaluations: 220, initialRadius: 0.75)
) { point in
    let x = point[0]
    let y = point[1]
    return .init(objective: x * x + y * y,
                 constraints: [(x - 2) * (x - 2) + y * y - 1])
}
```

The callback must accept trial points outside the supplied constraints and
variable bounds. Fixed coordinates retain their fixed values throughout.
The objective and residuals must be finite and have magnitude at most
`2^100`, the backend's model range. Equality residuals are handled as
paired inequalities. The evaluation budget includes simplex construction,
and callback errors propagate to the caller.

Check `feasible` and `maximumViolation` alongside the termination reason.
A run can reach the final radius with a remaining constraint violation.

## Powell LINCOA

`LincoaSolver` accepts a value-only objective and a `SparseLinearProblem`
containing continuous linear inequalities and variable bounds. The linear
objective coefficients are ignored. Check `LincoaSolver.isAvailable` on the
linked FFI. For example, this minimizes the distance squared from (2, 2)
subject to x + y ≤ 2.

```swift
let region = try SparseLinearProblem(
    objective: [0, 0], rows: 1, columns: 2,
    rowPointers: [0, 2], columnIndices: [0, 1], values: [1, 1],
    rowBounds: [.init(upper: 2)], variableBounds: [.init(), .init()]
)
let result = try LincoaSolver.minimize(initial: [0, 0], problem: region) { point in
    let dx = point[0] - 2
    let dy = point[1] - 2
    return dx * dx + dy * dy
}
```

The start must be feasible after setting fixed coordinates to their
specified values. Use inequalities for nonconstant linear rows. The
objective must be finite and defined at the solver's trial points, which
can lie outside the constraints and bounds. The result is the best evaluated
point that satisfies the configured absolute feasibility tolerance on the
original rows and bounds. The evaluation count includes interpolation
samples, and the termination reason distinguishes radius, evaluation,
and iteration limits.
