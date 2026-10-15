import XCTest
@testable import NumericCoreOptimization

final class SpiceNetlistTests: XCTestCase {
    func testParsesAndSolvesDCAndACLowPass() throws {
        let parsed = try SpiceNetlist.parse("""
        RC low pass
        V1 in 0 DC 1 AC 1
        R1 in out 1k
        C1 out 0 1u
        .OP
        .AC DEC 10 10 10k
        .END
        """)
        XCTAssertEqual(parsed.title, "RC low pass")
        XCTAssertEqual(parsed.circuit.devices.count, 3)
        let operating = try parsed.circuit.dcOperatingPoint()
        guard case .ac(let request) = parsed.analyses.last else { return XCTFail("missing AC") }
        let sweep = try parsed.circuit.acAnalysis(operatingState: operating.state,
            frequencies: request.frequencies, excitations: parsed.acExcitations)
        XCTAssertEqual(sweep.points.count, 31)
        XCTAssertTrue(sweep.points.allSatisfy { $0.residualNorm < 1e-9 })
    }

    func testModelsParametersInitialConditionsAndTransientSources() throws {
        let parsed = try SpiceNetlist.parse("""
        nonlinear
        .PARAM RVAL=2k
        .MODEL DMOD D(IS=1n N=2)
        V1 in 0 PULSE(0 1 1u 1n 1n 2u 5u)
        R1 in out {RVAL}
        D1 out 0 DMOD
        .IC V(out)=0.2
        .TRAN 10n 10u
        .END
        """)
        XCTAssertEqual(parsed.circuit.nodes[2].initialVoltage, 0.2)
        XCTAssertEqual(try parsed.circuit.transientBreakpoints(from: 0, to: 10e-6).count, 8)
    }

    func testReportsSourceLineForUnsupportedSemantics() throws {
        XCTAssertThrowsError(try SpiceNetlist.parse("bad\nQ1 c b e QMOD\n.END")) { error in
            guard let error = error as? SpiceNetlistError else { return XCTFail("wrong error") }
            XCTAssertEqual(error.diagnostics.first?.line, 2)
            XCTAssertTrue(error.description.contains("unsupported"))
        }
    }
}
