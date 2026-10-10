# Phase 24: local MINLP strengthening

The shared local MINLP solver now attempts rounded-and-polished integer
solutions at fractional nodes. Integer variables are rounded and fixed before
the continuous variables are reoptimized using the selected nonlinear
relaxation. This typically establishes a useful incumbent much earlier than
waiting for an integral relaxation.

Callers can supply an integer-feasible warm incumbent and choose depth-first or
best-local-bound node processing. Warm points are checked for dimensions,
integrality, bounds, nonlinear constraint feasibility, and finite objective
evaluation before use.

Swift and Rust expose matching diagnostics for heuristic attempts, successful
incumbents, and warm-incumbent acceptance. Since node relaxations are local and
the expression graph has no convexity certificate, local bounds affect search
order only; they do not enable certified pruning or global-optimality claims.
