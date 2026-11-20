# Modeling and circuit migration

- AMPL-style parsing, symbolic models, and lowering move to the standalone
  `NumericCoreAMPL` package. Change the product dependency to that package
  and keep `import NumericCoreAMPL`.
- Circuit models, modified nodal assembly, operating point, AC and transient
  analysis, and design utilities live in OhmLab. Use OhmLab’s
  `SpiceNetlistParser` for SPICE input. The moved MNA model is available from
  `OhmLabCore`. Its residual report type is `CircuitResidualDiagnostics`.
- Swift callers building numerical LPs or MILPs directly can use
  `SparseLinearSolver.solve(_:configuration:)` with `SparseLinearProblem`.
  Generic sparse solvers, DAE integration, and sensitivities stay in NumericCore.
- Model parsing tests travel with the language package. Circuit tests belong in
  OhmLab. NumericCoreValidation continues to test the numerical solver paths.

The Swift removal targets **2.0.0** so consumers of the 1.x products can retain
their existing dependency range. OhmLab and the new language package require
the new Swift release. Rust v0.35.0 retires the circuit modules and updates the
capability manifest. Release that Rust binary and sync its matching UniFFI
assets before tagging Swift 2.0.0. Publish the standalone package and release
the matching OhmLab update after Swift 2.0.0 is available.
