# Phase 59 — Multiphysics and design optimization

Phase 59 promotes the shared engineering representation into a coupled
multiphysics workflow. `MultiphysicsModel` partitions the global residual rows
into named disciplines while retaining one monolithic state, Jacobian, and
parameter space. The partition must cover every equation exactly once, making
discipline diagnostics unambiguous without weakening cross-discipline
couplings.

The steady solver applies sparse Newton steps to the complete coupled Jacobian,
with residual-decreasing backtracking and explicit residual, step, iteration,
and line-search termination. Results include global and per-discipline
residual norms and linear-solve counts. Parameter replacement preserves names,
units, topology, and constitutive graphs for repeat design evaluations.

`MultiphysicsDesignOptimizer` minimizes a graph-represented scalar response
over bounded engineering parameters. Each evaluation solves the coupled state,
differentiates the response graph, invokes Phase 57's implicit adjoint, and
passes the total derivative to L-BFGS-B. Warm states accelerate nearby design
evaluations, while a cold retry prevents a poor warm state from becoming a
false optimization failure.

The validation case couples field and thermal balance equations and recovers
an analytic regularized design optimum. Transient trajectory objectives,
partitioned co-simulation, contact topology changes, mesh morphing, and
multi-objective/Pareto algorithms remain later work.
