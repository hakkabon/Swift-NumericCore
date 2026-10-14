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

    func testControlledSourcesAndLevelOneNMOS() throws {
        let controlled = try CircuitModel(nodes: [
            .init(name: "0"), .init(name: "control"), .init(name: "out")
        ], referenceNode: 0, devices: [
            .voltageSource(name: "VC", positive: 1, negative: 0,
                           source: .dc(1), initialCurrent: 0),
            .voltageControlledCurrentSource(name: "G1", positive: 2, negative: 0,
                                            controlPositive: 1, controlNegative: 0,
                                            transconductance: 2),
            .resistor(name: "R1", positive: 2, negative: 0, resistance: 1),
            .voltageControlledVoltageSource(name: "E1", positive: 2, negative: 0,
                                            controlPositive: 1, controlNegative: 0,
                                            gain: -2, initialCurrent: 0),
        ])
        XCTAssertEqual(try controlled.dcOperatingPoint().nodeVoltages[2], -2, accuracy: 1e-12)

        let transistor = try CircuitModel(nodes: [
            .init(name: "0"), .init(name: "gate"), .init(name: "drain")
        ], referenceNode: 0, devices: [
            .voltageSource(name: "VG", positive: 1, negative: 0,
                           source: .dc(2), initialCurrent: 0),
            .voltageSource(name: "VD", positive: 2, negative: 0,
                           source: .dc(2), initialCurrent: 0),
            .nmosLevel1(name: "M1", drain: 2, gate: 1, source: 0,
                        transconductance: 1e-3, threshold: 1,
                        channelLengthModulation: 0),
        ])
        let result = try transistor.dcOperatingPoint()
        XCTAssertEqual(result.branchCurrents["VD"]!, -0.5e-3, accuracy: 1e-12)
    }

    func testDCContinuationAndPulseBreakpoints() throws {
        let pulse = CircuitWaveform.pulse(low: 0, high: 1, delay: 1,
                                          rise: 0.1, fall: 0.1,
                                          width: 0.5, period: 2)
        let circuit = try CircuitModel(nodes: nodes, referenceNode: 0, devices: [
            .diode(name: "D1", anode: 1, cathode: 0,
                   saturationCurrent: 1e-12, thermalVoltage: 0.026),
            .currentSource(name: "I1", positive: 0, negative: 1,
                           source: .transient(dc: 1e-3, waveform: pulse)),
        ])
        let result = try circuit.dcOperatingPointContinuation()
        XCTAssertEqual(result.continuationSteps, 9)
        XCTAssertLessThan(result.diagnostics.maximumKCLResidual, 1e-8)
        let points = try circuit.transientBreakpoints(from: 0, to: 5)
        XCTAssertEqual(points.count, 8)
        XCTAssertEqual(points.first!, 1, accuracy: 1e-12)
        XCTAssertEqual(points.last!, 3.7, accuracy: 1e-12)
    }
}
