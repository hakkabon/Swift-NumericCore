# Phase 64 — Stochastic and scenario optimization

`NumericCoreOptimization.StochasticOptimization` exposes the Rust scenario-tree
solver, finite-distribution sampling and policy evaluation, scenario reduction,
and continuous two-stage progressive hedging. A `ScenarioTree` can be built from
information-node blocks or a `BendersProblem`. Each decision vector is shared by
the terminal paths through its node. Mean–CVaR applies upper-tail risk to total
path cost, with confidence level `alpha` and weight `weight`.

Use `draw` and `solveSampleAverage` to fit a plan to an empirical distribution.
Use `evaluate` with independent draws to estimate the expected cost of a fixed
first-stage plan. The reported normal 95% interval is approximate. `reduce`
returns representative source indices and redistributed weights to use when
constructing a reduced model.

Use `hedge` for continuous two-stage expected-cost models. The returned
`HedgingCheckpoint` is Codable. Pass a decoded checkpoint back with the same
model, scenario order, penalty, and tolerance. Workers run locally. A hedging
result reports consensus residuals. Use fixed-decision evaluation to check
recourse and cost and the extensive-form solver when an audited bound is needed.

The provisional `stochastic-optimization` capability activates after the
release synchronization workflow installs the matching UniFFI bindings and Rust
binary. `StochasticOptimization.isAvailable` identifies whether the linked
package supports it.
