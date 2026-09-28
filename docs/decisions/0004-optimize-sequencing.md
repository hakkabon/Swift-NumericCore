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

## Update (MILP: BranchAndBoundSolver wired through to AMPL)
`nc-optimize::BranchAndBoundSolver` — see `Rust-NumericCore`'s ADR 0004
update for the algorithm itself (LP-relaxation branch-and-bound,
`RevisedSimplexSolver` as the required relaxation solver, scope
boundaries) — is now reachable from AMPL source text end to end. Three
coordinated changes made that possible:

- **Grammar**: `var_decl` gained an `integer` qualifier
  (`docs/design/ampl-grammar.md`'s EBNF, `AMPLLexer`/`AMPLParser`),
  usable in either order relative to `bound_clause`
  (`var x integer >= 0;` and `var x >= 0 integer;` both parse
  identically) — a deliberate extension for the same reason
  `linear_expr`'s leading-sign extension exists: an arbitrary fixed
  ordering would be a restriction with no grammatical justification.
- **`Model`/`CompiledProblem`**: `Model.addVariable(_:isInteger:)` and
  `CompiledProblem.variableIsInteger` carry the flag through presolve.
- **`Solve.swift`**: `LPSolverKind` (kept that name for continuity
  rather than renamed to `SolverKind`, despite now covering MILP too)
  gained `.branchAndBound`, calling `nc-ffi`'s new
  `solve_milp_branch_and_bound` via `FFIProblem`'s new `isInteger`
  field (default `[]`, so every pre-existing LP call site kept
  compiling unchanged).

`docs/design/ampl-grammar.md`'s MILP example is the concrete
end-to-end test in `SolveTests.swift` — solved via `.branchAndBound`
(integer optimum `(4, 0)`, objective `20`) and, on the identical model,
via `.simplex` (LP relaxation's fractional optimum `(3, 1.5)`,
objective `21`), deliberately checking both rather than only the
"obviously correct" solver choice, so the contrast itself is verified
rather than assumed.

## Update (Phase 3: complete LP/MILP integration)

`CompiledProblem.solve()` now selects branch-and-bound automatically when the
model contains integer variables and revised simplex otherwise. Explicit
`.simplex` and `.interiorPoint` remain available for deliberately solving an LP
relaxation. Solutions retain source variable names through
`variableValuesByName`, and `LPSolution.isVerified(tolerance:)` requires both
an optimal status and independently verified feasibility, integrality, and
objective reconstruction.

Presolve now rejects duplicate variable names, invalid direct-builder variable
references, non-finite values, and contradictory variable bounds. Objective
constants are retained outside the numerical coefficient vector and restored
in both the public objective and its independent diagnostic reconstruction.

Rust-NumericCore's corresponding Phase 3 boundary adds configurable LP/MILP
solves and branch-and-bound search reports (nodes, best bound, and gaps). Those
new calls require the next synchronized XCFramework/generated-bindings release;
the safe selection and named/verified Swift result improvements build against
the current v0.7.0 binary.
