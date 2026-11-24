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

Swift-NumericCore **1.1.0** is the last tag with the bundled
`NumericCoreAMPL` product. The split first appears in **1.2.0**, so a
dependency range covering all of 1.x can resolve without the bundled product.
Pin exactly **1.1.0** if you still rely on the bundled product during
migration.

OhmLab and standalone NumericCoreAMPL require Swift-NumericCore 2.x.
The extensive-form, local Benders, and distributed Benders paths were
qualified with Rust-NumericCore **v0.45.0**. Swift-NumericCore **2.0.0** ships
with the [Rust-NumericCore **v0.45.1** XCFramework](https://github.com/hakkabon/Rust-NumericCore/releases/tag/v0.45.1).
SwiftPM resolves the binary and its checksum from `Package.swift`; the
generated bindings and `.ffi-version` match that release.

Publish the standalone package and release the matching OhmLab update after
Swift 2.0.0 is available.
