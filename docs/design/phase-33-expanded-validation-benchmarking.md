# Phase 33: expanded validation and benchmarking

Phase 33 grows the production reference program from four to seven independent
cases. In addition to LP, QP, MILP, and nonlinear solver references, it now
checks presolve/postsolve equivalence, mixed-scale sparse row and transpose
products, and deterministic perturbation reproducibility. Every numerical
comparison remains scale-aware, finite, and suitable for deterministic CI.

Performance evidence is deliberately separate from correctness. The
`NumericCoreBenchmarks` executable measures sparse row activity and reversible
presolve at 100, 1,000, and 10,000 variables, performs a warm-up, and emits
machine-readable JSON. Run it in an optimized build:

```sh
NC_BENCH_ITERATIONS=20 swift run -c release NumericCoreBenchmarks
```

Wall-clock results are not assertions: machine load, architecture, compiler,
and thermal state belong in retained benchmark metadata. Regressions should be
confirmed on the same machine and toolchain before becoming release criteria.
