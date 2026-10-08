# Phase 18: production LP/MILP depth

`BranchAndBoundSolveOptions` now exposes the Rust engine's production controls:
absolute and relative gaps, depth-first or best-bound node selection,
most-fractional or learned pseudo-cost branching, and singleton-row bound
propagation. Existing scaling and incumbent warm-start controls remain intact.

`MILPSearchReport` carries the complete certificate back to Swift, including
the explicit termination reason, pruning counts, maximum depth, LP relaxation
count, propagated-bound count, and number of incumbents found.

Pseudo-cost branching and propagation are enabled by default. Both are
deterministic for a fixed model and option set. NumericCoreFFI and the generated
Swift bindings must be released together for the Phase 18 ABI.
