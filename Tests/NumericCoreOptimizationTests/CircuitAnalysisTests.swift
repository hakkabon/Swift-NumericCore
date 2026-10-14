import XCTest
@testable import NumericCoreOptimization

final class CircuitAnalysisTests: XCTestCase {
    private var nodes: [CircuitNode] { [.init(name: "0"), .init(name: "out")] }

    func testResistorCurrentSourceDCOperatingPoint() throws {
        let circuit = try CircuitModel(nodes: nodes, referenceNode: 0, devices: [
            .resistor(name: "R1", positive: 1, negative: 0, resistance: 2),
            .currentSource(name: "I1", positive: 0, negative: 1, source: .dc(1)),
        ])
        let result = try circuit.dcOperatingPoint()
        XCTAssertEqual(result.termination, .convergedResidual)
        XCTAssertEqual(result.nodeVoltages[1], 2, accuracy: 1e-12)
        XCTAssertTrue(result.diagnostics.finite)
        XCTAssertLessThan(result.diagnostics.maximumKCLResidual, 1e-12)
        XCTAssertEqual(result.diagnostics.maximumBranchResidual, 0)
    }

    func testVoltageSourceAddsBranchCurrentUnknown() throws {
        let circuit = try CircuitModel(nodes: nodes, referenceNode: 0, devices: [
            .voltageSource(name: "V1", positive: 1, negative: 0, source: .dc(5), initialCurrent: 0),
            .resistor(name: "R1", positive: 1, negative: 0, resistance: 10),
        ])
        let result = try circuit.dcOperatingPoint()
        XCTAssertEqual(result.nodeVoltages[1], 5, accuracy: 1e-12)
        XCTAssertEqual(result.branchCurrents["V1"]!, -0.5, accuracy: 1e-12)
        XCTAssertLessThan(result.diagnostics.maximumBranchResidual, 1e-12)
    }

    func testRCTransientUsesDAEStamp() throws {
        let circuit = try CircuitModel(nodes: nodes, referenceNode: 0, devices: [
            .resistor(name: "R1", positive: 1, negative: 0, resistance: 2),
            .capacitor(name: "C1", positive: 1, negative: 0, capacitance: 0.5),
            .currentSource(name: "I1", positive: 0, negative: 1, source: .dc(1)),
        ])
        let options = TimeIntegrationOptions(absoluteTolerance: 1e-5, relativeTolerance: 1e-4,
                                             initialStep: 0.01, maximumStep: 0.05)
        let result = try circuit.transient(from: 0, to: 1,
                                           initialState: [0], initialDerivative: [2],
                                           options: options)
        XCTAssertEqual(result.points.last!.state[0], 2 * (1 - exp(-1)), accuracy: 4e-3)
    }

    func testDiodeBiasAndWaveform() throws {
        let waveform = CircuitWaveform.sinusoidal(offset: 1, amplitude: 2,
                                                   frequency: 0.5, phase: 0)
        XCTAssertEqual(waveform.value(at: 0.5), 3, accuracy: 1e-12)
        let circuit = try CircuitModel(nodes: nodes, referenceNode: 0, devices: [
            .diode(name: "D1", anode: 1, cathode: 0,
                   saturationCurrent: 1e-12, thermalVoltage: 0.026),
            .currentSource(name: "I1", positive: 0, negative: 1, source: .dc(1e-3)),
        ])
        let result = try circuit.dcOperatingPoint(initial: [0.5])
        XCTAssertGreaterThan(result.nodeVoltages[1], 0)
        XCTAssertLessThan(result.nodeVoltages[1], 1)
    }
}
