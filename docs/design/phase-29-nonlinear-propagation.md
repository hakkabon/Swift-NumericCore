# Phase 29: nonlinear propagation and bound tightening

Phase 29 adds a public feasibility-based bound-tightening contractor for the
shared nonlinear expression graph. It alternates forward interval evaluation
with backward contraction through affine atoms, products and quotients where
zero exclusion makes inversion safe, `exp`, `log`, `sqrt`, and square powers.
Unsupported inverse images remain unchanged, preserving rigor rather than
guessing across disconnected domains.

Spatial branch-and-bound runs propagation at every node before constructing
its LP relaxation. Nonlinear constraint ranges and the current incumbent's
objective cutoff can therefore tighten the parameter box or prove the node
infeasible without an LP solve. The tightened box is shared by relaxation
generation, local solving, and branching.

Options control pass count and contraction tolerance. Results report total
passes, tightened endpoints, and nodes pruned directly by propagation. The
standalone API also exposes the contracted bounds and infeasibility status for
presolve and diagnostics.

The contractor deliberately represents one interval per variable. Future work
can add interval unions, monotone trigonometric inverses, affine arithmetic,
optimization-based bound tightening, and incremental contractor scheduling.
