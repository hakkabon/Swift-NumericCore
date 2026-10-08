# Sparse direct solvers and preconditioners

Phase 16 completes the public sparse linear-system path. `SparseLinearSolver`
accepts the existing canonical CSR representation and exposes two direct
methods: partial-pivoted sparse LU for general square systems and sparse
Cholesky for symmetric positive-definite systems. Both return independently
computed absolute and relative residuals plus factor storage counts. Invalid
shape, singularity, asymmetry, non-positive pivots, and non-finite input fail
explicitly.

The configurable iterative path now exposes conjugate gradient, BiCGSTAB, and
restarted GMRES through Swift. Available preconditioners are none, Jacobi,
zero-fill incomplete LU, and zero-fill incomplete Cholesky. Factor-based
preconditioners are constructed once per solve and reused at each iteration.
CG rejects ILU(0), whose nonsymmetric action does not preserve the method's
SPD assumptions; incomplete Cholesky is the factor preconditioner intended for
CG. ILU(0) is available for BiCGSTAB and GMRES.

The numerical implementations live in Rust-NumericCore. UniFFI transports CSR
values, options, termination states, solutions, and diagnostics. The generated
bindings and XCFramework therefore must be released together. The Rust factor
types can solve repeated right-hand sides; the current Swift API intentionally
starts with safe one-shot operations and can gain opaque reusable factor
handles later if profiling shows that repeated FFI construction is material.

This phase does not add fill-reducing orderings, supernodal/multifrontal
factorization, pivot-threshold tuning, or external SuiteSparse integration.
Those are separate production-scale extensions rather than hidden behavior in
the initial portable implementation.
