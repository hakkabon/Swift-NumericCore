import XCTest
@testable import NumericCoreOptimization

final class EngineeringModelTests: XCTestCase {
    private func unknown(_ name: String, _ role: EngineeringUnknownRole) -> EngineeringUnknown {
        .init(name: name, unit: "V", role: role)
    }

    func testDynamicComponentAssemblyAndParameterSensitivity() throws {
        // C*vDot + v/R - source; input=[time,v,vDot,R,C,source].
        let expression = NonlinearExpression(nodes: [
            .parameter(2), .parameter(4), .multiply(0, 1),
            .parameter(1), .parameter(3), .divide(3, 4), .add(2, 5),
            .parameter(5), .subtract(6, 7),
        ], output: 8)
        let model = try EngineeringModel(
            unknowns: [unknown("v", .differential)],
            parameters: [.init(name: "R", unit: "ohm", value: 2),
                         .init(name: "C", unit: "F", value: 3),
                         .init(name: "source", unit: "A", value: 1)],
            elements: [.init(name: "load", kind: "RC",
                ports: [.init(name: "p", unknown: 0)],
                equations: [.init(row: 0, expression: expression)])])
        let assembly = try model.assemble(time: 0, state: [2], derivative: [0.25])
        XCTAssertEqual(assembly.residuals[0], 0.75, accuracy: 1e-12)
        XCTAssertEqual(try assembly.jacobianState.multiplying(.init([1])).storage, [0.5])
        XCTAssertEqual(try assembly.jacobianDerivative.multiplying(.init([1])).storage, [3])
        XCTAssertEqual(try assembly.parameterJacobian.multiplying(.init([1, 0, 0])).storage, [-0.5])
    }

    func testTwoNodeElementScatteringAndIncidence() throws {
        let positive = NonlinearExpression(nodes: [.parameter(1), .parameter(2), .subtract(0, 1),
                                                    .parameter(5), .multiply(2, 3)], output: 4)
        let negative = NonlinearExpression(nodes: [.parameter(1), .parameter(2), .subtract(0, 1),
                                                    .parameter(5), .multiply(2, 3), .negate(4)], output: 5)
        let model = try EngineeringModel(
            unknowns: [unknown("u0", .algebraic), unknown("u1", .algebraic)],
            parameters: [.init(name: "k", unit: "N/m", value: 10)],
            elements: [.init(name: "spring", kind: "spring",
                ports: [.init(name: "a", unknown: 0, orientation: 1),
                        .init(name: "b", unknown: 1, orientation: -1)],
                equations: [.init(row: 0, expression: positive),
                            .init(row: 1, expression: negative)])])
        let assembly = try model.assemble(time: 0, state: [0.2, 0.1], derivative: [0, 0])
        XCTAssertEqual(assembly.residuals, [1, -1])
        XCTAssertEqual(try assembly.jacobianState.multiplying(.init([1, 1])).storage, [0, 0])
        XCTAssertEqual(try model.incidenceMatrix().multiplying(.init([2, 1])).storage, [1])
    }

    func testValidationRejectsUncoveredRows() {
        XCTAssertThrowsError(try EngineeringModel(
            unknowns: [unknown("a", .algebraic), unknown("b", .algebraic)],
            elements: [.init(name: "only-a", kind: "constraint",
                ports: [.init(name: "a", unknown: 0)],
                equations: [.init(row: 0,
                    expression: .init(nodes: [.parameter(1)], output: 0))])]))
    }

    func testEngineeringModelDrivesDAEIntegrator() throws {
        let model = try EngineeringModel(
            unknowns: [.init(name: "x", unit: "1", role: .differential,
                             initialValue: 1, initialDerivative: -1)],
            elements: [.init(name: "decay", kind: "first-order",
                ports: [.init(name: "x", unknown: 0)],
                equations: [.init(row: 0, expression: .init(
                    nodes: [.parameter(1), .parameter(2), .add(0, 1)], output: 2))])])
        let result = try TimeIntegrator.integrateDAE(
            from: 0, to: 1, initialState: model.initialState,
            initialDerivative: model.initialDerivative
        ) { time, state, derivative in
            try model.daeEvaluation(time: time, state: state, derivative: derivative)
        }
        XCTAssertEqual(result.points.last!.state[0], exp(-1), accuracy: 5e-4)
    }
}
