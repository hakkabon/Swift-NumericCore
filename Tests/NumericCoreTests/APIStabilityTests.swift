import XCTest
import NCBindings
import NumericCore

final class APIStabilityTests: XCTestCase {
    func testManifestIdentityIsFrozenForCompatibilityEpochOne() {
        XCTAssertEqual(NumericCoreAPI.manifestSchemaVersion, 1)
        XCTAssertEqual(NumericCoreAPI.compatibilityEpoch, 1)
        let identifiers = NumericCoreAPI.capabilities.filter { $0.identifier != "lp-decomposition" }
        XCTAssertEqual(identifiers.map(\.identifier), [
            "dae-integration",
            "dense-linear-algebra", "engineering-models", "fem", "global-minlp",
            "iterative-linear-solvers", "lp-qp-milp", "multiphysics-design",
            "nonlinear-equations", "nonlinear-optimization", "numerical-validation",
            "sparse-linear-algebra",
        ])
        if let decomposition = NumericCoreAPI.capability("lp-decomposition") {
            XCTAssertEqual(decomposition.stability, .provisional)
            XCTAssertEqual(decomposition.contractVersion, 1)
        }
    }

    func testManifestIsWellFormedAndQueryable() {
        let capabilities = NumericCoreAPI.capabilities
        XCTAssertEqual(Set(capabilities.map(\.identifier)).count, capabilities.count)
        XCTAssertEqual(capabilities.map(\.identifier), capabilities.map(\.identifier).sorted())
        XCTAssertTrue(capabilities.allSatisfy { $0.contractVersion > 0 })
        XCTAssertTrue(NumericCoreAPI.supports("lp-qp-milp", minimumStability: .stable))
        XCTAssertFalse(NumericCoreAPI.supports(
            "multiphysics-design", minimumStability: .provisional))
        XCTAssertFalse(NumericCoreAPI.supports("unknown-capability"))
    }

    func testLinkedRustManifestMatchesSwiftContract() {
        let rust = numericCoreApiManifest()
        XCTAssertEqual(Int(rust.schemaVersion), NumericCoreAPI.manifestSchemaVersion)
        XCTAssertEqual(Int(rust.compatibilityEpoch), NumericCoreAPI.compatibilityEpoch)

        let capabilities = rust.capabilities.map { capability -> NumericCoreCapability in
            let stability: NumericCoreAPIStability
            switch capability.stability {
            case .stable: stability = .stable
            case .provisional: stability = .provisional
            case .experimental: stability = .experimental
            }
            return .init(identifier: capability.identifier, stability: stability,
                         contractVersion: Int(capability.contractVersion))
        }
        let legacy: [NumericCoreCapability] = rust.rustPackageVersion == "0.34.0" ? [
            .init(identifier: "ampl-modeling", stability: .provisional),
            .init(identifier: "circuit-analysis", stability: .provisional),
        ] : []
        XCTAssertEqual(capabilities, legacy + NumericCoreAPI.capabilities,
                       "Catalog mismatch with Rust \(rust.rustPackageVersion)")

        if let expectedTag = ProcessInfo.processInfo.environment["NUMERICCORE_EXPECTED_RUST_TAG"] {
            XCTAssertEqual("v" + rust.rustPackageVersion, expectedTag)
        }
    }

    func testStableCapabilityContracts() {
        for identifier in [
            "dense-linear-algebra", "iterative-linear-solvers", "lp-qp-milp",
            "nonlinear-optimization", "numerical-validation", "sparse-linear-algebra",
        ] {
            XCTAssertEqual(NumericCoreAPI.capability(identifier),
                           .init(identifier: identifier, stability: .stable, contractVersion: 1))
        }
    }

    func testManifestHasStableCodableRepresentation() throws {
        let data = try JSONEncoder().encode(NumericCoreAPI.capabilities)
        XCTAssertEqual(try JSONDecoder().decode(
            [NumericCoreCapability].self, from: data), NumericCoreAPI.capabilities)
    }
}
