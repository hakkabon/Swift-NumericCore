# 0002 — Sparse v1 scope: CSR only

## Status
Accepted.

## Context
Sparse matrices have several standard formats, each suited to different
operations:
- **COO** (coordinate list) — trivial to build incrementally, poor for
  arithmetic.
- **CSR** (compressed sparse row) — efficient SpMV, natural for
  row-oriented iterative solvers (CG, GMRES).
- **CSC** (compressed sparse column) — needed by some factorization
  algorithms (e.g. certain sparse LU/Cholesky implementations) and for
  column-oriented access.

Three consumers exist or are planned for sparse matrices in this
project: `NumericCoreSparse` (general use), `NumericCoreGraph`
(adjacency/Laplacian, naturally row-oriented for most graph algorithms),
and the AMPL presolve layer (the constraint matrix `A` in `Ax {≤,=,≥} b`,
consumed by iterative or simplex-style solvers that are also
row-oriented).

## Decision
v1 implements **CSR only**, in both `nc-sparse` (Rust) and
`NumericCoreSparse` (Swift, currently a parallel pure-Swift
implementation pending FFI). SpMV is the only operation implemented.

COO is deferred until the AMPL presolve layer actually needs
incremental construction (at which point a `COO → CSR` conversion
function is the likely addition, not a full parallel COO type with its
own operation set). CSC is deferred until a specific sparse
factorization needs it.

## Consequences
- All three planned consumers (general sparse, graph, AMPL) share one
  format and one code path — less to maintain, easier to keep correct.
- Incrementally building a large sparse matrix (e.g. while parsing an
  AMPL model's constraint list one row at a time) is currently awkward
  with CSR's fixed row-pointer structure — building via
  `Vec<Vec<(col, value)>>` and converting once at the end (as
  `NumericCoreGraph::GraphBridge.adjacencyMatrix` already does) is the
  workaround until COO exists.
- Any future factorization needing CSC will require a real (not
  trivial) addition, not a quick wrapper.

## Alternatives considered
- **Implement COO, CSR, and CSC upfront.** Rejected: no current consumer
  needs COO's incremental-build property enough to justify it yet, and
  no current consumer needs CSC at all. Building all three now is
  exactly the kind of speculative generality this project's design
  principles try to avoid.

## Update — Phase 4 sparse assembly and iterative depth

`SparseMatrix` now accepts unordered coordinate entries and canonicalizes them
to CSR by sorting, duplicate coalescing, and zero removal. It also materializes
CSR transposes and validates complete row-pointer structure at construction.
CSC remains deferred until a sparse direct factorization actually requires it.

Rust-NumericCore adds warm-started Jacobi CG, BiCGSTAB, and restarted GMRES,
with distinct convergence, iteration-limit, and breakdown outcomes, plus
matching UniFFI exports. Those iterative calls become Swift-facing after the
next synchronized XCFramework/generated-bindings release; coordinate assembly
and transpose are already available in the Swift API without that release.
