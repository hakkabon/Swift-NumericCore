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
express a real LP, matching the LP-first sequencing in
`docs/decisions/0004-optimize-sequencing.md`.

Deliberately excluded from this first cut: `set` declarations and
indexed expressions (`sum {i in I} ...`), piecewise-linear terms, and
anything nonlinear. Add these as separate, later grammar extensions once
the flat/unindexed subset below is parsing and presolving correctly —
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

var_decl     = "var" , identifier , [ bound_clause ] , ";" ;
param_decl   = "param" , identifier , ":=" , number , ";" ;

bound_clause = ">=" , number
             | "<=" , number
             | ">=" , number , "," , "<=" , number ;

constraint_decl
             = "subject" , "to" , identifier , ":" ,
               linear_expr , relop , linear_expr , ";" ;

objective_decl
             = ( "minimize" | "maximize" ) , identifier , ":" ,
               linear_expr , ";" ;

linear_expr  = term , { ( "+" | "-" ) , term } ;
term         = [ number ] , identifier
             | number ;

relop        = "<=" | ">=" | "=" ;

identifier   = letter , { letter | digit | "_" } ;
number       = [ "-" ] , digit , { digit } , [ "." , { digit } ] ;
letter       = "a".."z" | "A".."Z" ;
digit        = "0".."9" ;
```

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
6. **Not yet done**: migrating the lexer/parser to the
   `hakkabon/Grammar`/`Lexer`/`Parser` packages, if that's still
   wanted, once their exact public APIs are in hand to write against.
7. **Not yet started**: `set` declarations, indexed expressions,
   piecewise-linear terms — deliberately deferred, per this doc's intro.
