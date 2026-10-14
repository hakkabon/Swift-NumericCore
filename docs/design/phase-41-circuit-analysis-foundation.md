# Phase 41: circuit-analysis foundation

`CircuitModel` is the typed Swift counterpart to Rust NumericCore's circuit
kernel. It maps named nodes and devices into a modified-nodal-analysis state:
all non-reference node voltages followed by the branch currents required by
ideal voltage sources and inductors. The reference node is fixed at zero by
elimination rather than by adding an artificial equation.

The supported stamps are resistors, capacitors, inductors, independent current
and voltage sources, and exponential diodes. Sources can carry DC values or
constant, sinusoidal, and pulse transient waveforms. The same analytic stamps
produce residuals, sparse state Jacobians, and sparse derivative Jacobians for
both DC and transient analysis.

DC operating points use `NonlinearSystemSolver`; transient analysis is a
circuit-oriented convenience over `TimeIntegrator.integrateDAE`. Results expose
node voltages, voltage-defined branch currents, and separate maximum KCL and
branch-equation residuals. The Swift and Rust APIs intentionally mirror one
another so a later backend/FFI decision does not change the modeling concepts.

This phase does not parse SPICE netlists. It also defers controlled sources,
compact transistor models, AC/noise analysis, topology validation, device
limiting and homotopy, discontinuity-aware stepping, and SPICE compatibility.
A future netlist or AMPL-like engineering front end should lower into this typed
representation rather than embed parsing rules in the numerical kernel.
