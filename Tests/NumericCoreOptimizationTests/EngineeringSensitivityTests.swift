import XCTest
@testable import NumericCoreOptimization

final class EngineeringSensitivityTests: XCTestCase {
    private func scalarModel(dynamic: Bool = false) throws -> EngineeringModel {
        // F = C*ydot + k*y - p. Inputs are [t,y,ydot,k,C,p].
        let expression = NonlinearExpression(nodes: [
            .parameter(4), .parameter(2), .multiply(0, 1),
            .parameter(3), .parameter(1), .multiply(3, 4), .add(2, 5),
            .parameter(5), .subtract(6, 7),
        ], output: 8)
        return try EngineeringModel(
            unknowns: [.init(name: "y", unit: "m", role: dynamic ? .differential : .algebraic)],
            parameters: [.init(name: "k", unit: "N/m", value: 4),
                         .init(name: "C", unit: "N s/m", value: 2),
                         .init(name: "p", unit: "N", value: 8)],
            elements: [.init(name: "balance", kind: "scalar",
                ports: [.init(name: "y", unknown: 0)],
                equations: [.init(row: 0, expression: expression)])])
    }

    func testSteadyForwardAndAdjointSensitivitiesAgree() throws {
        let result = try scalarModel().sensitivities(
            time: 0, state: [2], derivative: [0], responses: [
                .init(name: "displacement", stateGradient: [1],
                      directParameterGradient: [0, 0, 0]),
                .init(name: "scaled", stateGradient: [3],
                      directParameterGradient: [1, 0, 0]),
            ])
        XCTAssertEqual(result.stateSensitivities[0][0], -0.5, accuracy: 1e-12)
        XCTAssertEqual(result.stateSensitivities[1][0], 0, accuracy: 1e-12)
        XCTAssertEqual(result.stateSensitivities[2][0], 0.25, accuracy: 1e-12)
        XCTAssertEqual(result.responses[0].parameterGradient, [-0.5, 0, 0.25])
        XCTAssertEqual(result.responses[1].parameterGradient[0], -0.5, accuracy: 1e-12)
        XCTAssertLessThan(result.responses[0].maximumForwardAdjointMismatch, 1e-12)
        XCTAssertLessThan(result.maximumForwardResidualNorm, 1e-12)
    }

    func testImplicitDAEFactorUsesDerivativeJacobian() throws {
        let result = try scalarModel(dynamic: true).sensitivities(
            time: 0, state: [1], derivative: [2], derivativeSensitivityFactor: 3,
            responses: [.init(name: "state", stateGradient: [1],
                              directParameterGradient: [0, 0, 0])])
        // Effective tangent k + alpha*C = 10.
        XCTAssertEqual(result.stateSensitivities[2][0], 0.1, accuracy: 1e-12)
        XCTAssertEqual(result.responses[0].adjoint[0], 0.1, accuracy: 1e-12)
        XCTAssertEqual(result.derivativeSensitivityFactor, 3)
    }

    func testMalformedRequestAndSingularTangentFailClosed() throws {
        XCTAssertThrowsError(try scalarModel().sensitivities(
            time: 0, state: [2], derivative: [0], responses: [
                .init(name: "bad", stateGradient: [], directParameterGradient: [0, 0, 0]),
            ]))
        let singular = try EngineeringModel(
            unknowns: [.init(name: "y", unit: "m", role: .algebraic)],
            parameters: [.init(name: "p", unit: "N", value: 1)],
            elements: [.init(name: "load", kind: "source",
                ports: [.init(name: "y", unknown: 0)],
                equations: [.init(row: 0, expression: .init(
                    nodes: [.parameter(3)], output: 0))])])
        XCTAssertThrowsError(try singular.sensitivities(
            time: 0, state: [0], derivative: [0], responses: [
                .init(name: "y", stateGradient: [1], directParameterGradient: [0]),
            ]))
    }
}
