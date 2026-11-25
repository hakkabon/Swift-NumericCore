// swift-tools-version:5.9
import Foundation
import PackageDescription

// The release sync updates this binding and the binary together. Enable the
// optional solver bridges only when their generated APIs are present.
let generatedBindings = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Sources/NCBindings/Generated/nc_ffi.swift")
let generatedSource = (try? String(contentsOf: generatedBindings, encoding: .utf8)) ?? ""
let optionalSolverSettings: [SwiftSetting] = [
    ("public protocol FfiLpWorkspaceProtocol", "NUMERICCORE_LP_DECOMPOSITION_FFI"),
    ("public func solveBendersDecomposition(", "NUMERICCORE_BENDERS_FFI"),
    ("public func solveIntegerBendersDecomposition(", "NUMERICCORE_INTEGER_BENDERS_FFI"),
    ("public func solveScenarioTree(", "NUMERICCORE_STOCHASTIC_FFI"),
    ("public func solveNonlinearDecomposition(", "NUMERICCORE_NONLINEAR_DECOMPOSITION_FFI"),
    ("public protocol FfiSparseFactorizationProtocol", "NUMERICCORE_SPARSE_WORKSPACE_FFI"),
    ("public func integrateEngineeringTrajectory(", "NUMERICCORE_ENGINEERING_ADJOINTS_FFI"),
    ("public func startDistributedBenders(", "NUMERICCORE_DISTRIBUTED_BENDERS_FFI"),
    ("public func solveBobyqa(", "NUMERICCORE_BOBYQA_FFI"),
    ("public func solveCobyla(", "NUMERICCORE_COBYLA_FFI"),
].compactMap { marker, flag in
    generatedSource.contains(marker) ? .define(flag) : nil
}

// Package name kept as "NumericCore" (matching the product/module names
// consumers import) even though the repository is "Swift-NumericCore" —
// deliberately distinct from Apple's `swift-numerics`, see
// docs/decisions/0008-split-into-two-repos.md.
let package = Package(
    name: "NumericCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "NumericCore", targets: ["NumericCore"]),
        .library(name: "NumericCoreAccelerate", targets: ["NumericCoreAccelerate"]),
        .library(name: "NumericCoreMPS", targets: ["NumericCoreMPS"]),
        .library(name: "NumericCoreSparse", targets: ["NumericCoreSparse"]),
        .library(name: "NumericCoreGraph", targets: ["NumericCoreGraph"]),
        .library(name: "NumericCoreOptimization", targets: ["NumericCoreOptimization"]),
        .executable(name: "NumericCoreBenchmarks", targets: ["NumericCoreBenchmarks"]),
        .executable(name: "NumericCoreValidation", targets: ["NumericCoreValidation"]),
    ],
    targets: [
        // The compiled Rust core (nc-ffi), built by
        // Rust-NumericCore/scripts/build-xcframework.sh and published
        // as a checksummed GitHub release asset. Consumed as a remote
        // binaryTarget — no local vendoring, no Rust toolchain needed
        // to build this package. See ADR 0010 for the automated
        // release/sync pipeline (Rust-NumericCore's release.yml tags →
        // builds → publishes → dispatches; this repo's
        // .github/workflows/update-ffi.yml picks that up, updates the
        // url/checksum below via scripts/set_ffi_binary_target.py, and
        // opens a PR) and ADR 0009 for the local-path approach this
        // superseded.
        //
        // Note: `Sources/NCBindings/Generated/nc_ffi.swift` must always be
        // refreshed in lockstep with the framework (same release's
        // `nc_ffi.swift` asset) — a framework without matching bindings
        // (or vice versa) links or misbehaves, and SPM will not catch
        // the mismatch for you. The automated workflow keeps both in
        // sync in one PR; if updating by hand, do the same.
        .binaryTarget(
            name: "NumericCoreFFI",
            url: "https://github.com/hakkabon/Rust-NumericCore/releases/download/v0.45.1/NumericCoreFFI.xcframework.zip",
            checksum: "d34df46ab1b7316e803d7122cec7ce2543543633fcfb9f3383b0b6b418294868"
        ),

        // Thin Swift wrapper around the UniFFI-generated bindings
        // (checked in under Sources/NCBindings/Generated/ — see that
        // directory's README) plus the hand-written adapter in
        // FFIBridge.swift. Not part of the public API surface —
        // NumericCore/NumericCoreSparse are the only targets that
        // should import this.
        .target(
            name: "NCBindings",
            dependencies: ["NumericCoreFFI"],
            exclude: ["Generated/README.md"]
        ),

        .target(
            name: "NumericCore",
            dependencies: ["NCBindings"],
            swiftSettings: optionalSolverSettings
        ),

        .target(
            name: "NumericCoreAccelerate",
            dependencies: ["NumericCore"]
        ),

        .target(
            name: "NumericCoreMPS",
            dependencies: ["NumericCore"]
        ),

        .target(
            name: "NumericCoreSparse",
            dependencies: ["NumericCore", "NCBindings"],
            swiftSettings: optionalSolverSettings
        ),

        .target(
            name: "NumericCoreGraph",
            dependencies: ["NumericCoreSparse"]
        ),

        .target(
            name: "NumericCoreOptimization",
            dependencies: ["NumericCore", "NumericCoreSparse", "NCBindings"],
            swiftSettings: optionalSolverSettings
        ),

        .testTarget(
            name: "NumericCoreTests",
            dependencies: ["NumericCore", "NumericCoreAccelerate", "NumericCoreSparse", "NumericCoreGraph", "NCBindings"],
            resources: [.copy("Fixtures")]
        ),

        .testTarget(
            name: "NumericCoreOptimizationTests",
            dependencies: ["NumericCore", "NumericCoreSparse", "NumericCoreOptimization"]
        ),
        .executableTarget(
            name: "NumericCoreBenchmarks",
            dependencies: ["NumericCoreOptimization"],
            path: "Benchmarks/NumericCoreBenchmarks"
        ),
        .executableTarget(
            name: "NumericCoreValidation",
            dependencies: ["NumericCore", "NumericCoreOptimization"],
            path: "Benchmarks/NumericCoreValidation"
        ),
    ]
)
