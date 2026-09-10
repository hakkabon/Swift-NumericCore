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
        // Raw unsafe wrapper around the Rust core (nc-ffi via UniFFI).
        // Not part of the public API surface — NumericCore is the only
        // target that should import this.
        //
        // Currently a plain source target with NO dependency on
        // Rust-NumericCore's binary — see ADR 0006 (v1 storage is a
        // Swift array) and RustFallbackBackend, which reimplements the
        // Rust logic directly in Swift rather than calling through.
        // That's why this package builds standalone today with zero
        // external binary dependency, which matters for downstream
        // consumers (e.g. Swift-DataLens) who need this to "just build."
        //
        // Once Rust-NumericCore publishes a tagged XCFramework release
        // (see that repo's scripts/build-xcframework.sh and
        // .github/workflows/release.yml), switch this target to:
        //
        //   .binaryTarget(
        //       name: "NumericCoreFFI",
        //       url: "https://github.com/hakkabon/Rust-NumericCore/releases/download/vX.Y.Z/NumericCoreFFI.xcframework.zip",
        //       checksum: "<from `swift package compute-checksum`>"
        //   ),
        //
        // and change this NCBindings target to depend on
        // "NumericCoreFFI" plus the UniFFI-generated Swift bindings
        // (checked in under Sources/NCBindings/Generated/ — copy them
        // from the release build's bindings/*.swift output; they are
        // source, not part of the binary, and must ship alongside it).
        // See docs/decisions/0008-split-into-two-repos.md for the full
        // versioning/pinning plan.
        .target(
            name: "NCBindings",
            dependencies: []
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
            dependencies: ["NumericCore", "NumericCoreSparse"]
            // Add "Grammar", "Parser", "Lexer" here once the DSL front end
            // is implemented against those packages instead of ad hoc
            // parsing.
        ),

        .testTarget(
            name: "NumericCoreTests",
            dependencies: ["NumericCore", "NumericCoreAccelerate", "NumericCoreSparse", "NumericCoreGraph"]
        ),

        .testTarget(
            name: "NumericCoreAMPLTests",
            dependencies: ["NumericCoreAMPL"]
        ),
    ]
)
