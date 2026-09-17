# 0004 — AMPL/optimization layer: LP → MILP → NLP sequencing

## Status
Accepted.

## Context
An AMPL-style system decomposes into four subsystems: modeling language,
presolve, solver interface, and solvers. The solver piece itself splits
further into LP (tractable, well-understood — simplex or interior-point),
MILP (branch-and-bound/cut — substantial, and competitive
general-purpose MILP is a research area commercial vendors spend decades
on), and NLP (needs automatic differentiation, has deep numerical
stability subtleties — flagged during scoping as the item most likely to
produce open-ended surprises).

Estimated effort discussed during scoping: LP-complete system ~2–3 years
at solo/part-time pace; adding MILP ~3.5–5 years; full NLP support
pushes further still. Building all three simultaneously risks a
long stretch with nothing working end-to-end.

## Decision
Sequence strictly: **modeling language → presolve → `Problem` format →
LP solver**, get that whole pipeline working end-to-end, and only then
decide whether MILP or NLP is actually needed based on real usage.

Concretely in this codebase:
- `nc-optimize::Problem`/`Solution`/`Solver` (the ASL-equivalent
  interface) is built now, deliberately solver-agnostic, so it doesn't
  need to change shape when a real solver replaces `StubSolver`.
- `StubSolver` exists purely to prove the pipeline (parse → presolve →
  `Problem` → `Solver` → `Solution`) can be wired and tested end-to-end
  before any real numerical solving exists.
- No MILP- or NLP-specific types exist yet anywhere in `nc-optimize`.
  `Bound` (used for both variable and constraint bounds) is deliberately
  general enough to support range constraints and fixed variables, which
  LP already needs — it wasn't designed with MILP integrality
  constraints in mind and will need extension (e.g. an `is_integer: Vec<bool>`
  field on `Problem`) if/when MILP work starts.

## Consequences
- The project can demonstrate real value (declaring a model, solving an
  LP) well before MILP/NLP exist, rather than nothing working until
  everything works.
- `Problem`'s current shape may need a breaking addition for MILP
  (integrality flags) and a larger one for NLP (nonlinear expression
  trees can't be represented as a flat objective vector + linear
  constraint matrix — NLP likely needs a materially different `Problem`
  variant, not an extension of this one).
- Whether MILP or NLP is built at all is deferred to a real decision
  point informed by actual usage, not decided now.

## Alternatives considered
- **Design `Problem` to accommodate MILP/NLP from day one** (e.g.
  including integrality flags and nonlinear expression support now).
  Rejected: adds real complexity to the LP path for capabilities that
  may never be exercised, and risks guessing wrong about what NLP's
  actual data model needs before any NLP work has started.

## Update (LP: both solvers implemented, wired through to AMPL)
`nc-optimize::{RevisedSimplexSolver, InteriorPointSolver}` are both
real, tested `Solver` implementations now (`StubSolver` is gone from
the active path) — see `Rust-NumericCore`'s ADR 0004 for the full
detail on each (formulation, scope boundaries, cross-validation between
the two on shared test problems). **Solver selection is explicit, not
policy-based** — `NumericCoreAMPL`'s `CompiledProblem.solve(using:)`
(`Solve.swift`) takes an `LPSolverKind` the caller picks, mirroring the
Rust-side decision rather than adding a `DispatchPolicy`-style
auto-selector.

The full loop from AMPL source text to a solved LP is closed:
`AMPLParser.parse(_:)` → `Model.compile()` → `.solve(using:)`, crossing
into Rust via `nc-ffi`'s `solve_lp_simplex`/`solve_lp_interior_point`
(new `NCBindings` types: `FFIProblem`/`FFIBound`/`FFISolution`/
`FFISolveStatus`, plus a new `FFIError.solverError` case for any
`OptimizeError` — see ADR 0005's update). `docs/design/ampl-grammar.md`'s
own worked example is one of the end-to-end tests
(`SolveTests.swift`), checked against both solvers.
