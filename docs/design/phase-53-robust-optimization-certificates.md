# Phase 53 — Robust optimization certificates

Phase 53 separates a solver's termination report from independently recomputed
evidence about the returned point. `OptimizationCertifier` produces a typed
claim (`optimality`, `feasibility`, `candidate`, or `rejected`), named residual
metrics with their tolerances, and non-fatal structural warnings.

| Evidence | Scope of the claim |
| --- | --- |
| Linear primal audit | `certifyLinear` rebuilds the objective, row and variable feasibility, and integrality from the supplied model and point. A successful status and passing evidence establish `.feasibility` within the configured tolerances. |
| Caller-supplied gap | The named `caller-supplied gap` metric checks that the scalar is finite and belongs to `[0, tolerance.gap]`. Its provenance is the caller, and a passing check preserves the `.feasibility` claim. A failing check returns `.rejected`. |
| Local nonlinear stationarity | The reported gradient or KKT residual measures first-order stationarity at the returned point. Check primal feasibility and termination alongside it. Its scope is local and first order. |
| Convex QP KKT evidence | `certifyConvexQP` checks convexity and recomputes the objective and primal-dual residuals. Passing evidence establishes numerical `.optimality` for the validated convex model at the configured tolerances. |
| Bounds from a search | Local Benders, branch-and-bound, and spatial search report the bounds and gap produced by the solve. Limits can leave partial evidence. Read the termination reason and the bounds together. |
| Independently replayed proof | `DistributedBendersCoordinator.verify` checks exported witnesses against the original continuous two-stage LP, rebuilds cuts and bounds, and computes a claim. `.optimality` requires a verified incumbent and a closed gap under the audit tolerances. `.bounds` can describe partial evidence, and `.infeasibility` requires a verified infeasibility witness. |

`verified` applies to the displayed `OptimizationCertificate.claim`. In
particular, a verified feasibility claim describes the point and its
reconstructed objective.

For convex quadratic programs, the certifier independently recomputes primal
feasibility, the objective, stationarity, dual sign feasibility, and
complementarity from the primal point and row and variable multipliers. It also
checks the numerical rank of the active constraint gradients. Dependent or
overdetermined active sets are reported as warnings because degeneracy does not
by itself invalidate valid KKT evidence.

The certificate checks dimensions, tolerances, and numerical values. Invalid
tolerance settings raise an error. Non-finite or inconsistent solution
evidence fails closed as `.rejected`. The standard validation corpus covers
convex QP KKT evidence, a zero gap supplied for a feasible suboptimal LP point,
local and distributed Benders limits, and replay of valid and altered proofs.

This phase does not yet claim rigorous interval enclosures, LP/MILP Farkas
infeasibility certificates, unbounded rays, or exact branch-and-bound proof
logs. Those require solver interfaces that preserve the corresponding dual,
ray, and search-tree evidence and are natural extensions of this format.
