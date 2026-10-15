# Phase 56 — Continuum FEM

Phase 56 extends the FEM layer from bars and scalar diffusion to two-dimensional
small-strain linear elasticity. `ContinuumFEMModel` uses three-node
constant-strain triangles with two translational degrees of freedom per node,
and reuses the established sparse assembly, exact prescribed-DOF elimination,
reaction recovery, and Cholesky solve.

`LinearElasticContinuumMaterial` supports isotropic plane stress and plane
strain with validated Young's modulus, Poisson ratio, and thickness. Element
body forces are assembled with the consistent constant-load vector, while
nodal forces continue to use the common FEM load representation. Clockwise and
counter-clockwise connectivity recover the same physical strain because the
strain-displacement matrix retains signed orientation while integration uses
positive area.

Each solved element reports engineering strain
`[epsilon_xx, epsilon_yy, gamma_xy]`, stress
`[sigma_xx, sigma_yy, tau_xy, sigma_zz]`, in-plane principal stresses,
three-dimensional von Mises stress, area, and strain energy. The global result
also checks recovered element energy against the assembled global energy.

Validation includes an analytic uniaxial plane-stress patch test that recovers
axial displacement, Poisson contraction, stress, free-DOF equilibrium, and
energy, plus a plane-strain body-force case that exercises out-of-plane stress
recovery. The patch test is part of the standard reproducibility corpus in both
Swift and Rust.

The phase deliberately remains linear and triangular. Quadrilateral and
higher-order elements, numerical quadrature families, three-dimensional
solids, continuum mass matrices and dynamics, thermal strain, nonlinear
materials, geometric nonlinearity, contact, mesh import, error estimators, and
adaptive refinement remain future work.
