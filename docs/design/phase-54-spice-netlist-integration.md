# Phase 54 — SPICE netlist integration

Phase 54 adds a SPICE-compatible textual front end to the existing typed
`CircuitModel`. The parser is deliberately a compiler boundary: circuit syntax,
engineering suffixes, model cards, and analysis directives are resolved before
the numerical MNA, DAE, and AC solvers run. SPICE syntax is not embedded in the
linear algebra or nonlinear solver layers, and netlists are not translated
through AMPL because circuit topology and dynamic device stamps carry semantics
that a generic optimization grammar would otherwise obscure.

The supported vertical subset includes:

- case-insensitive named nodes, ground aliases `0` and `gnd`, comments, and
  continuation lines;
- engineering values from tera through femto, `.PARAM`, `.IC`, `.MODEL`,
  `.OP`, `.TRAN`, `.AC`, and `.END`;
- resistors, capacitors, inductors, independent voltage/current sources,
  VCCS/VCVS controlled sources, diodes, and three-terminal level-1 NMOS devices
  whose body is tied to source;
- `DC`, `AC`, `SIN`, and `PULSE` source specifications; and
- linear, decade, and octave AC frequency generation.

`ParsedSpiceNetlist` retains the compiled circuit, requested analyses, AC source
phasors, title, and source-located warnings. Syntax and semantic failures carry
line numbers. Unknown element types and lossy device semantics fail explicitly;
unsupported dot directives are retained as warnings so callers can decide
whether their workflow permits them.

The standard numerical-validation corpus parses an RC low-pass netlist and runs
its DC operating point and AC sweep, checking the DC solution, frequency grid,
and numerical residuals. Focused tests also cover parameters, diode models,
initial conditions, pulse breakpoints, and source-located rejection.

This is an intentional engineering subset rather than a claim of full SPICE
compatibility. Subcircuits, includes/libraries, behavioral sources, mutual
inductors, transmission lines, temperature models, BSIM devices, noise,
sensitivity syntax, and vendor dialect extensions remain future work. They
should be added only when the typed circuit representation can preserve their
semantics and the numerical kernel can validate them.
