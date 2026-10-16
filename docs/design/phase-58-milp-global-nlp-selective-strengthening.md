# Phase 58 — MILP/global-NLP selective strengthening

Phase 58 adds a deliberately selective cut family at the intersection of
mixed-integer linear optimization and factorable global nonlinear relaxation.
When an integer parameter `x` is the direct operand of a square graph atom
`z = x^2`, the global MINLP solver adds the integer-hull secants

`z >= (2k + 1)x - k(k + 1)`

for adjacent integers `k` and `k + 1` in the current node domain. These rows
are valid for every integer point and dominate the continuous square epigraph
between integers. They can close a relaxation gap at the root without spatial
or integer branching while preserving the existing global certificate.

Generation is enabled by default, can be disabled, and is capped per node by
`maximumIntegerEnvelopeCuts`. The result reports the cumulative number of cuts
actually generated. Cuts are rebuilt after propagation and integer-bound
normalization, so they reflect the current node rather than the original box.

The scope is intentionally narrow. General Gomory/MIR cuts, nonlinear RLT
products, affine operands, higher integer powers, cut aging, and a persistent
global cut pool remain future work. Restricting this phase to a mathematically
exact integer hull avoids weakening certificates with heuristic inequalities.
