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
