# Phase 17: solver scaling and warm starts

Swift exposes Rust's reversible LP/MILP equilibration through
`SimplexSolveOptions`, `InteriorPointSolveOptions`, and
`BranchAndBoundSolveOptions`. Scaling is on by default and can be disabled for
diagnostics or reproducibility comparisons.

`BranchAndBoundSolveOptions.initialIncumbent` accepts values in the compiled
model's variable order. Rust validates the candidate before using it, so an
invalid or fractional incumbent throws instead of silently corrupting pruning.
The incumbent is returned if a node limit stops the search before a better
integer solution is found.

Convex QP results expose `warmStart`, retaining the primal vector and both dual
blocks for a related follow-up solve. Sparse linear and statistical solvers keep
their existing initial-solution support, giving the ecosystem consistent reuse
semantics across repeated numerical workloads.

The FFI source and binary must be released together as NumericCoreFFI v0.13.0.
