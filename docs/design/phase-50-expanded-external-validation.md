# Phase 50 — Expanded external validation

Phase 50 moves the release-gating corpus beyond exclusively hand-constructed
examples. Two independently maintained problems are stored as deterministic,
offline fixtures and run by the existing numerical-validation workflow.

- **NIST StRD Misra1a** validates nonlinear least squares against NIST's
  certified two-parameter solution and residual sum of squares. Both the native
  Swift solver and the Rust solver through UniFFI are checked.
- **CUTEst HS71** validates constrained nonlinear optimization against the
  official SIF definition and reported solution. It checks all four primal
  variables, the objective, and feasibility on both nonlinear backends.

`ValidationCase` now carries optional provenance: collection, problem name,
citation, and source URL. Existing internal cases remain source-free, while
external cases must retain their identity in the structured report. The main
validation program grows from seven to nine cases, and the complete suite still
runs without network access.

The fixtures are intentionally small enough for pull-request CI. They establish
the ingestion and provenance contract for later Netlib, Maros–Mészáros,
MIPLIB, broader CUTEst, and additional NIST subsets; they do not claim coverage
equivalent to those complete collections.
