import XCTest
@testable import NumericCoreOptimization

final class CircuitACAnalysisTests: XCTestCase {
    private func lowPass(resistance: Double) throws -> CircuitModel {
        try CircuitModel(nodes: [
            .init(name: "0"), .init(name: "in"), .init(name: "out")
        ], referenceNode: 0, devices: [
            .voltageSource(name: "V1", positive: 1, negative: 0,
                           source: .dc(0), initialCurrent: 0),
            .resistor(name: "R1", positive: 1, negative: 2,
                      resistance: resistance),
            .capacitor(name: "C1", positive: 2, negative: 0, capacitance: 1),
        ])
    }

    func testLowPassMatchesClosedFormResponse() throws {
        let model = try lowPass(resistance: 1)
        let operating = try model.dcOperatingPoint()
        let sweep = try model.acAnalysis(
            operatingState: operating.state,
            frequencies: [1 / (2 * .pi)],
            excitations: [.init(deviceName: "V1", magnitude: 1)]
        )
        let output = sweep.points[0].unknowns[1]
        XCTAssertEqual(output.magnitude, 1 / sqrt(2), accuracy: 1e-10)
        XCTAssertEqual(output.phase, -.pi / 4, accuracy: 1e-10)
        XCTAssertLessThan(sweep.points[0].residualNorm, 1e-12)
    }

    func testResponseOptimizationRecoversResistance() throws {
        let result = try CircuitOptimization.optimizeAC(
            variables: [.init(name: "R1", initial: 2, lower: 0.2, upper: 3)],
            excitations: [.init(deviceName: "V1", magnitude: 1)],
            targets: [.magnitude(frequency: 1 / (2 * .pi), unknown: 1,
                                 target: 1 / sqrt(2), weight: 1)]
        ) { try self.lowPass(resistance: $0[0]) }
        XCTAssertEqual(result.parameters[0], 1, accuracy: 2e-4)
        XCTAssertLessThan(result.objective, 1e-10)
    }
}
