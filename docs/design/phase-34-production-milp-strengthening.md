# Phase 34: production MILP strengthening

Phase 34 strengthens the existing Rust-backed branch-and-bound path without
introducing a second MILP API. Before search, eligible nonnegative binary
knapsack rows receive deterministic minimal-cover inequalities. At every node,
bound propagation now isolates variables in general linear rows rather than
only reading singleton rows, iterating to a fixed point and rounding integer
bounds inward.

The existing `roundingHeuristic` option now means rounding and LP repair:
integer variables are fixed to their rounded relaxation values and the
remaining continuous LP is solved again. This turns many otherwise infeasible
rounded vectors into valid incumbents while retaining independent feasibility
and integrality verification.

No FFI schema change is required. Existing `boundsTightened`,
`relaxationsSolved`, `heuristicAttempts`, and `heuristicSuccesses` counters
account for the additional work, and all pruning and gap claims remain based
on valid relaxation bounds.
