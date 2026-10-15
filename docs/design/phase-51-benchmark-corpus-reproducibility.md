# Phase 51 — Benchmark corpus and reproducibility

Phase 51 promotes the validation program to a reproducible benchmark corpus.
Each `ValidationCase` now carries a stable identifier, numerical family, and
cumulative execution tier in addition to its metrics and optional provenance.
The same contract exists in Rust.

- `smoke` runs the fast LP, QP, MILP, and nonlinear checks.
- `standard` adds presolve/postsolve, mixed-scale sparse operations,
  deterministic perturbations, NIST StRD Misra1a, and CUTEst HS71.
- `extended` is reserved for larger licensed corpora and scheduled runs; it
  currently contains the full standard suite.

`ValidationSnapshot` provides a deterministically ordered, timestamp-free
Codable artifact. Its manifest exposes case IDs, families, tiers, metric names,
and provenance. Baseline comparison reports missing cases or metrics,
pass-to-fail transitions, and normalized-error degradation. Timing is excluded
from correctness snapshots because shared-runner wall time is not reproducible;
the existing benchmark executable remains the performance evidence path.

Generate the standard report with:

```bash
swift run -c release NumericCoreValidation standard
```

The numerical-validation workflow uploads that JSON on pull requests and main
branch updates. All current fixtures remain embedded and operate without
network access. Future corpus additions must provide stable IDs, explicit
tolerances and tiers, and provenance for externally maintained problems.
