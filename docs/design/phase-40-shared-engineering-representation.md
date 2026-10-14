# Phase 40: shared engineering representation

Phase 40 introduces the common intermediate representation into which future
SPICE and FEM front ends compile. It stays below domain syntax and above the
sparse nonlinear and time-integration kernels.

`EngineeringModel` owns named, unit-bearing unknowns and parameters plus a set
of elements. Unknown roles distinguish differential, algebraic, multiplier,
and reference quantities. Elements expose oriented ports and residual-row
contributions. Their signed incidence matrix captures topology without
assuming electrical nodes or mechanical degrees of freedom.

Element constitutive laws reuse `NonlinearExpression`. For `n` ports and `p`
parameters, expression inputs are ordered as time, `n` states, `n` state
derivatives, and `p` parameters. Exact expression gradients scatter into
sparse `F_y`, `F_yDot`, and `F_p`; duplicate contributions are coalesced by the
CSR assembler.

`EngineeringAssembly.daeEvaluation()` connects the assembled residual and
Jacobian blocks directly to Phase 39. This is sufficient for modified nodal
analysis and element residual assembly, while netlist parsing, reference-node
elimination, FEM mesh/material definitions, and specialized device models
remain intentionally separate future layers.
