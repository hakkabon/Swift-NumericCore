import XCTest
@testable import NumericCoreOptimization

final class FEMDynamicsTests: XCTestCase {
    private func bar() -> TrussFEMModel {
        .init(nodes: [.init(x: 0, y: 0), .init(x: 2, y: 0)],
              materials: [.init(youngModulus: 200, area: 3, density: 5)],
              elements: [.init(nodes: [0, 1], material: 0)],
              constraints: [.init(dof: 0, value: 0), .init(dof: 1, value: 0),
                            .init(dof: 3, value: 0)])
    }

    func testAxialBarModalFrequencyIsMassNormalized() throws {
        let result = try bar().modalAnalysis(modeCount: 1)
        XCTAssertEqual(result.angularFrequencies[0], sqrt(3 * 200 / (5 * 4)), accuracy: 1e-10)
        XCTAssertLessThan(result.maximumRelativeResidual, 1e-12)
        XCTAssertLessThan(result.maximumMassOrthogonalityError, 1e-12)
        XCTAssertEqual(result.modeShapes[0][0], 0)
    }

    func testNewmarkFreeVibrationConservesEnergy() throws {
        let options = FEMDynamicOptions(timeStep: 0.01, steps: 100)
        let result = try bar().dynamicResponse(
            options: options, initialDisplacement: [0, 0, 0.1, 0],
            initialVelocity: [0, 0, 0, 0],
            loadHistory: [[FEMNodalLoad]](repeating: [], count: options.steps + 1))
        let energies = result.states.map { $0.kineticEnergy + $0.strainEnergy }
        XCTAssertEqual(energies.last!, energies[0], accuracy: 1e-10)
        XCTAssertLessThan(result.maximumRelativeEquilibriumResidual, 1e-10)
    }
}
