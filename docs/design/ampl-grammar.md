# A minimal AMPL-subset grammar

**Status: implemented.** `AMPLLexer.swift`/`AMPLParser.swift`/
`Presolve.swift` implement everything below — a hand-rolled
recursive-descent parser, not (yet) the `Grammar`/`Lexer`/`Parser`
packages this doc originally sketched using; see `Model.swift`'s
module docs for why. This doc remains the source of truth for the
grammar itself and stays accurate to what's implemented; the "Next
steps" section at the bottom is updated to reflect what's actually left.

Working sketch for `NumericCoreAMPL`'s modeling-language front end,
intended as the starting grammar to hand to the existing
`Grammar`/`Lexer`/`Parser` Swift packages (see ADR 0005's sibling
reasoning: reuse what already exists rather than hand-rolling a new
parser). This is **not** full AMPL — it's the smallest subset that can
express LP, MILP, and unindexed smooth nonlinear models.

Still excluded: `set` declarations and indexed expressions
(`sum {i in I} ...`), piecewise-linear terms, and user-defined functions.
Add these as separate later grammar extensions —
indexed expressions in particular change the shape of the AST
significantly (an expression becomes a function of an index tuple, not
a fixed value) and are worth getting right in isolation rather than
designing alongside everything else at once.

One implemented extension beyond the EBNF below: `linear_expr` accepts
an optional leading `+`/`-` before its first term (so `-3 x + 2 y` parses
without the `0 - 3 x + 2 y` workaround the literal grammar would
otherwise require) — see `AMPLParser`'s doc comment.

## EBNF

```ebnf
model        = { statement } ;
statement    = var_decl | param_decl | constraint_decl | objective_decl ;

var_decl     = "var" , identifier , { bound_clause | "integer" } , ";" ;
param_decl   = "param" , identifier , ":=" , number , ";" ;

bound_clause = ">=" , number
             | "<=" , number
             | ">=" , number , "," , "<=" , number ;

constraint_decl
             = "subject" , "to" , identifier , ":" ,
               algebraic_expr , relop , algebraic_expr , ";" ;

objective_decl
             = ( "minimize" | "maximize" ) , identifier , ":" ,
               algebraic_expr , ";" ;

algebraic_expr = sum_expr ;
sum_expr     = product_expr , { ( "+" | "-" ) , product_expr } ;
product_expr = unary_expr , { ( "*" | "/" ) , unary_expr
                            | unary_expr } ;
unary_expr   = [ "+" | "-" ] , power_expr ;
power_expr   = primary , [ "^" , signed_number ] ;
primary      = number | identifier | "(" , algebraic_expr , ")"
             | function , "(" , algebraic_expr , ")" ;
function     = "exp" | "log" | "sqrt" | "sin" | "cos" ;
signed_number = [ "+" | "-" ] , number ;

linear_expr  = term , { ( "+" | "-" ) , term } ;
term         = [ number ] , identifier
             | number ;

relop        = "<=" | ">=" | "=" ;

identifier   = letter , { letter | digit | "_" } ;
number       = [ "-" ] , digit , { digit } , [ "." , { digit } ] ;
letter       = "a".."z" | "A".."Z" ;
digit        = "0".."9" ;
```

The `linear_expr` productions document the affine subset retained for
compatibility. The parser now consumes `algebraic_expr`; expressions that admit
an affine projection still compile through the original LP/MILP path.

## Nonlinear example

```ampl
var x >= 0;
minimize distance: (x - 2)^2;
subject to unit: x^2 <= 1;
```

`Model.compileNonlinear()` lowers this to the shared nonlinear graph.
`CompiledNonlinearProblem.solve()` selects SQP for constrained models and
bounded L-BFGS for unconstrained models; Swift and Rust backends are available.

## Example model in this subset

```ampl
var x >= 0;
var y >= 0, <= 10;

maximize profit: 3 x + 2 y;

subject to capacity: x + y <= 4;
subject to demand: x <= 3;
```

This compiles (via `Model.compile()` in `Presolve.swift`) to a
`CompiledProblem` like:

```text
objective      = [-3, -2]               // maximize negated to minimize form
objectiveSign  = -1                     // multiply solver's result by this to report in the original (maximize) sense
constraints    = [[1, 1],                // capacity: x + y <= 4
                  [1, 0]]                // demand:   x <= 3
rowBounds      = [(nil, 4), (nil, 3)]   // (lower, upper); nil = unbounded that direction
variableLowerBounds = [0, 0]
variableUpperBounds = [nil, 10]
```

`objectiveSign` is `+1` for a `minimize` objective (no negation
happened) and `-1` for `maximize` — see `CompiledProblem`'s doc comment.

## MILP example — the `integer` qualifier

```ampl
var x >= 0 integer;
var y >= 0 integer;

maximize profit: 5 x + 4 y;

subject to c1: 6 x + 4 y <= 24;
subject to c2: x + 2 y <= 6;
```

`integer` may appear anywhere among a `var_decl`'s qualifiers, in
either order relative to `bound_clause` — `var x integer >= 0;` and
`var x >= 0 integer;` both parse identically. Solving this model needs
`.solve(using: .branchAndBound)` specifically:
`.simplex`/`.interiorPoint` both ignore `CompiledProblem.variableIsInteger`
entirely and return the LP relaxation's optimum — for this exact model,
`(x, y) = (3, 1.5)`, objective `21` — a genuinely fractional answer
that silently satisfies neither variable's `integer` qualifier if the
wrong solver is picked. `.branchAndBound` returns the correct integer
optimum, `(x, y) = (4, 0)`, objective `20`. Both are exercised as tests
in `SolveTests.swift`, specifically to make that contrast visible
rather than assert only the "obviously correct" solver choice.

## What the parser produces

`AMPLParser.parse(_:)` calls `Model`'s builder methods directly
(`addVariable`/`addParameter`/`addConstraint`/`setObjective`) — no
separate parse-tree/AST type sits in between, per the plan below. An
identifier inside a `linear_expr` is resolved against both the model's
declared variables and its declared parameters: a variable reference
becomes a coefficient, a parameter reference folds into the
expression's constant at parse time (this is what makes `param_decl`
actually useful — the literal EBNF's `term` production doesn't
distinguish the two, but the semantics require it).

## Next steps, in order

1. ~~Write the lexical spec~~ — done, `AMPLLexer.swift`, hand-rolled
   rather than built on `Lexer`/`Lexer-FSA` (see `Model.swift`'s module
   docs for why).
2. ~~Parse the grammar above~~ — done, `AMPLParser.swift`, hand-rolled
   recursive descent rather than built on `Grammar`/`LL-Parsing`, for
   the same reason.
3. ~~Wire parser actions to call `Model`'s builder methods~~ — done,
   directly, no intermediate AST (small enough grammar that one isn't
   earning its complexity yet — revisit if/when `set`/indexed-expression
   support is added).
4. ~~`Presolve.swift` — `Model` → `CompiledProblem`~~ — done.
5. ~~Wiring `CompiledProblem` through `NCBindings` to
   `nc-optimize::Solver`~~ — done: `Solve.swift`'s
   `CompiledProblem.solve(using:)`, backed by `nc-ffi`'s
   `solve_lp_simplex`/`solve_lp_interior_point`. `AMPLParser.parse(_:)`
   → `Model.compile()` → `.solve(using:)` is now a complete path from
   AMPL source text to an actual solved LP — this doc's own worked
   example, above, is one of the tests (`SolveTests.swift`) exercising
   exactly that path, checked against both solvers.
6. ~~MILP: the `integer` qualifier, `BranchAndBoundSolver`~~ — done:
   grammar extended (`var_decl`'s EBNF above), `Model`/`CompiledProblem`
   carry per-variable integrality, `Solve.swift` gained
   `.branchAndBound`, `nc-ffi` exports `solve_milp_branch_and_bound`.
   See "MILP example" above — its two tests (solved via `.branchAndBound`
   vs. `.simplex` on the identical model) are the concrete
   demonstration of why solver choice matters once a model declares an
   integer variable.
7. **Not yet done**: migrating the lexer/parser to the
   `hakkabon/Grammar`/`Lexer`/`Parser` packages, if that's still
   wanted, once their exact public APIs are in hand to write against.
8. ~~Nonlinear scalar expressions and constrained solve integration~~ — done:
   arithmetic precedence, parentheses, constant powers, elementary functions,
   graph lowering, bounded L-BFGS, SQP, augmented Lagrangian, and Swift/Rust
   execution are covered end to end.
9. MINLP now compiles to the shared nonlinear graph and uses local
   branch-and-bound with specialized NLP relaxations. Certified global MINLP,
   `set` declarations, indexed expressions, piecewise-linear terms, and
   user-defined functions are not yet implemented.
