// swift-tools-version:5.9
import Foundation
import PackageDescription

let environment = ProcessInfo.processInfo.environment
let numericCore: Package.Dependency
if let localPath = environment["NUMERICCORE_PACKAGE_PATH"] {
    numericCore = .package(name: "Swift-NumericCore", path: localPath)
} else {
    guard let tag = environment["NUMERICCORE_SWIFT_TAG"],
          let version = Version(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag) else {
        fatalError("Set NUMERICCORE_PACKAGE_PATH or NUMERICCORE_SWIFT_TAG")
    }
    numericCore = .package(url: "https://github.com/hakkabon/Swift-NumericCore.git", exact: version)
}

let package = Package(
    name: "NumericCoreConsumerSmoke",
    platforms: [.macOS(.v13)],
    dependencies: [numericCore],
    targets: [
        .executableTarget(name: "NumericCoreConsumerSmoke", dependencies: [
            .product(name: "NumericCore", package: "Swift-NumericCore"),
            .product(name: "NumericCoreSparse", package: "Swift-NumericCore"),
            .product(name: "NumericCoreOptimization", package: "Swift-NumericCore"),
        ]),
    ]
)
