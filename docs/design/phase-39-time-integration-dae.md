# Phase 39: time integration and DAE foundation

Phase 39 introduces the transient-simulation substrate needed by circuit and
mechanical models without embedding SPICE or FEM policy in the numerical core.

`TimeIntegrator.integrate` implements adaptive Dormand–Prince 5(4), weighted
RMS error control, forward and reverse integration, observer cancellation,
directional terminal/nonterminal zero crossings, and piecewise cubic Hermite
dense output through `TimeIntegrationResult.state(at:)`.

`TimeIntegrator.integrateDAE` accepts residual-form index-1 systems
`F(t, y, yDot) = 0` with analytic state and derivative Jacobians. It applies
Newton-corrected backward Euler and step doubling for error estimation.
`DAEEvaluation.massMatrix` builds the common `M*yDot - f(t,y)` representation;
`M` may be singular for semi-explicit algebraic constraints.

Both paths fail closed on malformed dimensions or non-finite evaluations and
report accepted/rejected steps, function and Jacobian evaluations, Newton work,
events, cancellation, limits, and numerical failure. Swift and Rust implement
matching callback contracts locally; callback execution is intentionally not
routed through UniFFI.
