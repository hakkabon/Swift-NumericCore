# Phase 43: AC analysis and circuit optimization

`CircuitModel.acAnalysis` reuses the transient residual's analytic Jacobian
blocks. At a DC operating point, the state Jacobian is the small-signal
conductance matrix `G` and the derivative Jacobian is the storage matrix `C`.
Each requested frequency solves `(G + j omega C)x = b` using the equivalent real
block matrix `[G, -omega C; omega C, G]`. This includes RLC dynamics and the
local diode and NMOS conductances at the chosen bias.

AC excitations name independent current or voltage sources and provide a
magnitude and phase. Results retain every MNA unknown as a real/imaginary pair
with magnitude and phase accessors, allowing callers to select node voltages or
branch currents through the model's public unknown-index mapping.

`CircuitOptimization.optimizeAC` provides the first circuit synthesis loop.
Named variables carry initial values and finite bounds; a builder closure maps
them into a typed circuit. Weighted magnitude targets are evaluated after DC
continuation and AC analysis. Bound-aware central differences provide initial
design sensitivities, while the existing L-BFGS-B implementation supplies the
bounded search and convergence report.

The current real block solver is dense because native complex sparse kernels are
not yet active in NumericCore. Sparse complex factorization, adjoint gradients,
phase and group-delay objectives, process/temperature corners, tolerance and
yield optimization, netlist AC declarations, and noise analysis are deferred.
