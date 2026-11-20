# Phase 67 — Engineering-scale adjoints

Use `EngineeringModel.adjointSensitivities` for scalar responses at a steady
operating point or a single implicit step. Each response returns a total
parameter gradient and transpose solve diagnostics. The existing
`sensitivities` method also computes forward state sensitivities for
independent conformance checks. Multiphysics design now uses the
adjoint-only method.

Construct an `EngineeringTrajectory` with a model and a strictly increasing
time grid. The sparse backward-Euler integrator retains checkpoint states.
Call `adjoints` with several `EngineeringTrajectoryResponse` values to share
one replay pass. Each response may supply a terminal expression, a running
expression integrated by right-endpoint quadrature, or both. Graph inputs
are time, all states, all derivatives, and parameters in that order.

The result returns the discrete objective value, its parameter gradient
with the initial state fixed, and a separate initial state gradient. The
latter can be contracted through parameter-dependent initialization. Check
the primal residual and the adjoint backward error alongside the returned
gradients. `checkpointStride` controls how many states are saved and how
much replay is needed.

The provisional `engineering-adjoints` capability activates after the
matching UniFFI release is synchronized. Check
`EngineeringTrajectory.isAvailable` before constructing a trajectory.
Single-point adjoints also have a Swift implementation for earlier pins.
Trajectory gradients apply to the prescribed time grid.
