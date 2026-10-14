# Phase 45: FEM dynamics and modal analysis

The planar truss model now carries material density and assembles the standard
consistent translational mass matrix alongside the existing sparse stiffness
matrix. Static models remain source-compatible because Swift defaults density
to zero; modal and dynamic entry points require every participating material to
have positive density.

`modalAnalysis(modeCount:)` applies homogeneous Dirichlet constraints, reduces
both sparse matrices, and solves the symmetric generalized eigenproblem
`K phi = lambda M phi`. A Cholesky congruence converts it to a standard
symmetric problem. Returned modes are sorted by frequency, reconstructed in the
full global-DOF space, mass normalized, and accompanied by eigen-residual and
mass-orthogonality diagnostics.

`dynamicResponse` integrates `M u'' + C u' + K u = f(t)` using the
average-acceleration Newmark method (`beta = 1/4`, `gamma = 1/2`). Rayleigh
damping uses `C = alpha M + beta K`; the constant effective matrix is factored
once. Every time state contains full displacement, velocity, acceleration,
kinetic energy, and strain energy, while the result reports the maximum reduced
equilibrium residual.

This phase intentionally supports linear truss dynamics and fixed homogeneous
supports. Sparse eigensolvers, reusable sparse dynamic factorizations,
time-varying prescribed motion, continuum elasticity, thermal transients,
nonlinear dynamics, and frequency-response analysis remain future extensions.
