# A minimal AMPL-subset grammar

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

This should compile (once the presolve layer exists) to an
`nc_optimize::Problem` roughly like:

```text
objective     = [3, 2]                  // maximize -> negate for minimize-form solvers
constraints   = [[1, 1],                // capacity: x + y <= 4
                 [1, 0]]                // demand:   x <= 3
row_bounds    = [(-inf, 4), (-inf, 3)]
var_bounds    = [(0, +inf), (0, 10)]
```

Note the objective sense (`maximize` vs `minimize`) has to be resolved
during presolve, since `nc_optimize::Problem` (ADR 0004) only expresses
`minimize c^T x` — `maximize` compiles to `minimize -c^T x`, with the
sign flipped back on the reported objective value before it's shown to
the user.

## What the parser needs to produce

A `Model` (see `Sources/NumericCoreAMPL/Model.swift`) already has
the shape for variable declarations. The parser's job is to turn source
text matching the grammar above into calls against that same builder
API — `addVariable(name:lowerBound:upperBound:)`, plus the not-yet-written
`addConstraint`/`setObjective` — rather than producing a separate parse
tree type that then needs a second translation step into `Model`. This
keeps the parser's output format tied to one place
(`Model`'s public API) instead of two things that can drift apart.

## Next steps, in order

1. Write the lexical spec (token classes: keyword, identifier, number,
   relop, `;`, `:`) using the existing `Lexer`/`Lexer-FSA` package.
2. Feed the EBNF above into `Grammar` for FIRST/FOLLOW computation and
   grammar-class analysis (this is a small LL(1)-shaped grammar — no
   ambiguity expected, so `LL-Parsing` should suffice without needing
   `LR-Parsing`/`Earley-Parser`'s extra power).
3. Wire parser actions to call `Model`'s builder methods directly (see
   above) rather than building an intermediate AST — this is a small
   enough grammar that a separate AST type is unlikely to earn its
   complexity, though revisit this if `set`/indexed-expression support
   later makes a real AST worthwhile.
4. Only then: `Presolve.swift` — `Model` → `CompiledProblem` — is the
   next file to write, per `Model.swift`'s module docs.
