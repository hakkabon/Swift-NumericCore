// swift-tools-version:5.9
import PackageDescription

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
        .library(name: "NumericCoreAMPL", targets: ["NumericCoreAMPL"]),
    ],
    dependencies: [
        // Uncomment once the Grammar/Lexer/Parser packages are ready to be
        // pulled in for NumericCoreAMPL's modeling-language front end.
        // .package(url: "https://github.com/hakkabon/Grammar", branch: "main"),
        // .package(url: "https://github.com/hakkabon/Parser", branch: "main"),
        // .package(url: "https://github.com/hakkabon/Lexer", branch: "main"),
    ],
    targets: [
        // The compiled Rust core (nc-ffi), built by
        // Rust-NumericCore/scripts/build-xcframework.sh. Wired as a
        // *local path* binary target for now — see
        // Frameworks/README.md for how it gets there
        // (scripts/update-ffi.sh, or automatically via
        // .github/workflows/update-ffi.yml on each Rust-NumericCore
        // version tag) and ADR 0009 for why local-path
        // rather than a remote URL, and what changes once
        // Rust-NumericCore starts tagging releases:
        //
        //   .binaryTarget(
        //       name: "NumericCoreFFI",
        //       url: "https://github.com/hakkabon/Rust-NumericCore/releases/download/vX.Y.Z/NumericCoreFFI.xcframework.zip",
        //       checksum: "<from the release body — Rust-NumericCore's release.yml prints it>"
        //   ),
        //
        // Note: `Sources/NCBindings/Generated/nc_ffi.swift` must always be
        // refreshed in lockstep with the framework (same release's
        // `nc_ffi.swift` asset) — a framework without matching bindings
        // (or vice versa) links or misbehaves, and SPM will not catch
        // the mismatch for you.
        .binaryTarget(
            name: "NumericCoreFFI",
            path: "Frameworks/NumericCoreFFI.xcframework"
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
            dependencies: ["NCBindings"]
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
            dependencies: ["NumericCore", "NCBindings"]
        ),

        .target(
            name: "NumericCoreGraph",
            dependencies: ["NumericCoreSparse"]
        ),

        .target(
            name: "NumericCoreAMPL",
            dependencies: ["NumericCore", "NumericCoreSparse", "NCBindings"]
            // Add "Grammar", "Parser", "Lexer" here once the DSL front end
            // is implemented against those packages instead of ad hoc
            // parsing.
        ),

        .testTarget(
            name: "NumericCoreTests",
            dependencies: ["NumericCore", "NumericCoreAccelerate", "NumericCoreSparse", "NumericCoreGraph", "NCBindings"]
        ),

        .testTarget(
            name: "NumericCoreAMPLTests",
            dependencies: ["NumericCoreAMPL", "NumericCore"]
        ),
    ]
)
