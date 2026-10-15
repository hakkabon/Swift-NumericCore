import XCTest
@testable import NumericCoreOptimization

final class ContinuumFEMTests: XCTestCase {
    func testPlaneStressTrianglePassesUniaxialPatchTest() throws {
        let model = ContinuumFEMModel(
            nodes: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 0, y: 1)],
            materials: [.init(youngModulus: 200, poissonRatio: 0.3)],
            // Clockwise connectivity must produce the same physical field.
            elements: [.init(nodes: [0, 2, 1], material: 0)],
            constraints: [.init(dof: 0, value: 0), .init(dof: 1, value: 0),
                          .init(dof: 3, value: 0), .init(dof: 4, value: 0)],
            loads: [.init(dof: 2, value: 5)])
        let result = try model.solve()
        XCTAssertEqual(result.staticResult.values[2], 0.05, accuracy: 1e-12)
        XCTAssertEqual(result.staticResult.values[5], -0.015, accuracy: 1e-12)
        XCTAssertEqual(result.elements[0].stress[0], 10, accuracy: 1e-10)
        XCTAssertEqual(result.elements[0].stress[1], 0, accuracy: 1e-10)
        XCTAssertEqual(result.elements[0].vonMisesStress, 10, accuracy: 1e-10)
        XCTAssertLessThan(result.maximumElementEnergyMismatch, 1e-12)
        XCTAssertLessThan(result.staticResult.maximumFreeResidual, 1e-12)
    }

    func testPlaneStrainRecoversOutOfPlaneStressAndBodyForce() throws {
        let model = ContinuumFEMModel(
            nodes: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 0, y: 1)],
            materials: [.init(youngModulus: 100, poissonRatio: 0.25,
                              kinematics: .planeStrain)],
            elements: [.init(nodes: [0, 1, 2], material: 0, bodyForceX: 6)],
            constraints: [.init(dof: 0, value: 0), .init(dof: 1, value: 0),
                          .init(dof: 3, value: 0), .init(dof: 4, value: 0)])
        let result = try model.solve()
        XCTAssertTrue(result.elements[0].stress[3].isFinite)
        XCTAssertEqual(result.staticResult.reactions.reduce(0,+), -3, accuracy: 1e-10)
    }
}
