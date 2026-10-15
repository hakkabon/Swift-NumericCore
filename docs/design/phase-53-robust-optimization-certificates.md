# Phase 53 — Robust optimization certificates

Phase 53 separates a solver's termination report from independently recomputed
evidence about the returned point. `OptimizationCertifier` produces a typed
claim (`optimality`, `feasibility`, `candidate`, or `rejected`), named residual
metrics with their tolerances, and non-fatal structural warnings.

For linear models, the certifier recomputes the original-model objective,
row and variable feasibility, and integrality. A successful solve is certified
as feasible, not optimal, unless the caller supplies a finite independently
established global gap. This deliberately avoids deriving an optimality claim
from solver status alone while the production LP interface does not expose a
complete dual or ray certificate.

For convex quadratic programs, the certifier independently recomputes primal
feasibility, the objective, stationarity, dual sign feasibility, and
complementarity from the primal point and row and variable multipliers. It also
checks the numerical rank of the active constraint gradients. Dependent or
overdetermined active sets are reported as warnings because degeneracy does not
by itself invalidate valid KKT evidence.

All dimensions, tolerances, and numerical values are checked, and non-finite or
inconsistent evidence fails closed as `rejected`. The standard validation
corpus contains an independently certified convex-QP case, while focused tests
also corrupt a valid solution to prove that the verifier detects bad evidence.

This phase does not yet claim rigorous interval enclosures, LP/MILP Farkas
infeasibility certificates, unbounded rays, or exact branch-and-bound proof
logs. Those require solver interfaces that preserve the corresponding dual,
ray, and search-tree evidence and are natural extensions of this format.
