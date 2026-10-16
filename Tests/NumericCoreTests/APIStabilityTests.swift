import XCTest
@testable import NumericCore

final class APIStabilityTests: XCTestCase {
    func testManifestIdentityIsFrozenForCompatibilityEpochOne() {
        XCTAssertEqual(NumericCoreAPI.manifestSchemaVersion, 1)
        XCTAssertEqual(NumericCoreAPI.compatibilityEpoch, 1)
        XCTAssertEqual(NumericCoreAPI.capabilities.map(\.identifier), [
            "ampl-modeling", "circuit-analysis", "dae-integration",
            "dense-linear-algebra", "engineering-models", "fem", "global-minlp",
            "iterative-linear-solvers", "lp-qp-milp", "multiphysics-design",
            "nonlinear-equations", "nonlinear-optimization", "numerical-validation",
            "sparse-linear-algebra",
        ])
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

    func testManifestHasStableCodableRepresentation() throws {
        let data = try JSONEncoder().encode(NumericCoreAPI.capabilities)
        XCTAssertEqual(try JSONDecoder().decode(
            [NumericCoreCapability].self, from: data), NumericCoreAPI.capabilities)
    }
}
