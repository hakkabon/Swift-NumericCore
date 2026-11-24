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
their existing dependency range. OhmLab and NumericCoreAMPL require
Swift-NumericCore 2.x. The minimum supported pairing for NumericCoreAMPL's
extensive-form, local Benders, and distributed Benders paths is
Swift-NumericCore **2.0.0** with the
[Rust-NumericCore **v0.45.0** XCFramework](https://github.com/hakkabon/Rust-NumericCore/releases/tag/v0.45.0).
SwiftPM resolves the Rust binary and its checksum from Swift-NumericCore's
manifest. Its generated bindings and `.ffi-version` identify the same Rust
release, which includes the circuit split and both Benders interfaces.

Publish the standalone package and release the matching OhmLab update after
Swift 2.0.0 is available.
