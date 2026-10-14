import XCTest
@testable import NumericCoreOptimization

final class FEMFoundationTests: XCTestCase {
    func testThermalTriangleRecoversLinearTemperatureField() throws {
        let model = ThermalFEMModel(
            nodes: [.init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 0, y: 1)],
            materials: [.init(conductivity: 2)],
            elements: [.init(nodes: [0, 1, 2], material: 0)],
            constraints: [.init(dof: 0, value: 0), .init(dof: 1, value: 1)],
            loads: [.init(dof: 2, value: 0)]
        )
        let result = try model.solve()
        XCTAssertEqual(result.values[2], 0, accuracy: 1e-12)
        XCTAssertLessThan(result.maximumFreeResidual, 1e-12)
        XCTAssertEqual(result.reactions[0] + result.reactions[1], 0, accuracy: 1e-12)
    }

    func testAxialBarReturnsDisplacementStressAndReaction() throws {
        let model = TrussFEMModel(
            nodes: [.init(x: 0, y: 0), .init(x: 2, y: 0)],
            materials: [.init(youngModulus: 200, area: 3)],
            elements: [.init(nodes: [0, 1], material: 0)],
            constraints: [.init(dof: 0, value: 0), .init(dof: 1, value: 0),
                          .init(dof: 3, value: 0)],
            loads: [.init(dof: 2, value: 30)]
        )
        let result = try model.solve()
        XCTAssertEqual(result.staticResult.values[2], 0.1, accuracy: 1e-12)
        XCTAssertEqual(result.elements[0].stress, 10, accuracy: 1e-12)
        XCTAssertEqual(result.elements[0].axialForce, 30, accuracy: 1e-12)
        XCTAssertEqual(result.staticResult.reactions[0], -30, accuracy: 1e-12)
    }
}
