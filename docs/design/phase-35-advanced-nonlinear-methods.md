# Phase 35: advanced nonlinear methods

Phase 35 adds two complementary unconstrained optimization methods in native
Swift and Rust.

`TrustRegionNewtonCG` minimizes a smooth objective using its value, gradient,
and Hessian-vector product. A truncated Steihaug conjugate-gradient iteration
solves each trust-region subproblem without assembling a Hessian. It detects
negative curvature, truncates steps at the trust-region boundary, compares
actual and predicted reduction, and adapts the radius. Results expose function
evaluations, Hessian products, accepted steps, final radius, and termination.

`PowellDirectionSet` implements M. J. D. Powell's classical derivative-free
direction-set idea. It performs bracketed golden-section line minimizations,
tracks the direction producing the largest decrease, and replaces that
direction with the cycle displacement. It is useful when derivatives are
unavailable or unreliable.

The Powell implementation is intentionally identified as a direction-set
method. It is not presented as NEWUOA, BOBYQA, COBYLA, or a reproduction of
Powell's later interpolation-based Fortran codes. Both APIs fail closed on
invalid dimensions and non-finite evaluations and use deterministic stopping
rules. Their matched Swift/Rust closure APIs require no FFI schema change.
