# Phase 44: FEM foundation

The Swift FEM layer mirrors the Rust implementation and builds directly on
`NumericCoreSparse`. It defines planar nodes, explicit global-DOF constraints
and loads, indexed material tables, and validated element connectivity.

`ThermalFEMModel` assembles three-node constant-gradient triangles for steady
heat conduction. Each element contributes its conductivity/thickness stiffness
and a consistent uniform heat-source vector. `TrussFEMModel` assembles the
rotated stiffness of two-node small-displacement bars and recovers axial strain,
stress, and force after the global solve.

Both paths assemble canonical sparse matrices, eliminate prescribed DOFs
exactly, solve the reduced symmetric positive-definite system with sparse
Cholesky, and reconstruct the full state. Results retain the global stiffness
matrix, reactions, strain energy, maximum free-DOF residual, and reduced-system
relative residual. Invalid topology, degenerate elements, unsupported models,
and singular reduced systems fail explicitly.

The foundation does not yet include mesh file formats, reusable symbolic
assembly, quadrature families, plane stress/strain or solid elements, consistent
mass matrices, dynamic integration, nonlinear constitutive laws, contact,
adaptive refinement, or topology/shape optimization.
