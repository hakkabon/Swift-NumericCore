# Phase 46: model-based derivative-free optimization

`ModelBasedTrustRegion` fills the gap between direct-search methods and
derivative-based trust-region solvers. At each center it samples a coordinate
interpolation stencil and constructs a diagonal quadratic model. Centered
unequal-step formulas are used in the interior; two-point one-sided formulas
maintain geometry at active bounds.

The model proposes a bound-feasible trust-region step. Actual versus predicted
reduction controls acceptance and radius contraction or expansion. The public
result records objective evaluations, model builds, accepted steps, one-sided
stencils, final radius, projected-gradient norm, and the last reduction ratio.
Evaluation limits, observer cancellation, non-finite objectives, malformed
bounds, and fixed dimensions have explicit outcomes or errors.

This is deliberately described as a model-based quadratic trust-region method,
not as BOBYQA. It establishes the interpolation, geometry, box projection, and
trust-region contracts needed for a future full quadratic interpolation set,
minimum-Frobenius-change updates, and Powell-style geometry-improvement steps.

The later `BobyqaSolver` API uses the same PRIMA-based BOBYQA implementation
as Rust-NumericCore through a synchronous UniFFI objective callback.
Use `BobyqaSolver.isAvailable` to query the capability on the linked release.
A callback receives the full feasible point even when some coordinates are
fixed. Its errors propagate to the caller. The configured evaluation budget
includes initialization, and `radiusReached` reports trust-region resolution.

```swift
let result = try BobyqaSolver.minimize(
    initial: [0, 0],
    bounds: [.init(lower: -2, upper: 2), .init(lower: -2, upper: 2)]
) { x in
    let a = x[0] + x[1] - 1
    let b = x[0] - x[1]
    return a * a + 3 * b * b
}
```

## Unconstrained Powell methods

`NewuoaSolver` and `UobyqaSolver` minimize a finite, deterministic,
value-only objective. NEWUOA uses `2n + 1` interpolation points and
least-change quadratic updates. UOBYQA is a dense reference variant that
determines all the coefficients of the quadratic using
`(n + 1)(n + 2)/2` points. It supports up to 16 variables.

```swift
let result = try NewuoaSolver.minimize(
    initial: [-1.2, 1], options: .init(maxEvaluations: 500, initialRadius: 0.5)
) { x in
    let a = x[1] - x[0] * x[0]
    let b = 1 - x[0]
    return 100 * a * a + b * b
}
```

Switch to `UobyqaSolver.minimize` to compare against the full model using
the same options. Check the solver's `isAvailable` property for support
in the linked FFI. The budget includes the starting point and interpolation
samples. The result reports the best objective evaluation and its point,
and the termination reason records how the local search stopped.
