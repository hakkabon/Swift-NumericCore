import XCTest
import NumericCore
@testable import NumericCoreOptimization

final class EngineeringSensitivityTests: XCTestCase {
    private func scalarModel(dynamic: Bool = false, load: Double = 8) throws -> EngineeringModel {
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
                         .init(name: "p", unit: "N", value: load)],
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

    func testAdjointOnlyAgreesWithForwardContraction() throws {
        let result = try scalarModel().adjointSensitivities(time: 0, state: [2], derivative: [0], responses: [
            .init(name: "scaled", stateGradient: [3], directParameterGradient: [1, 0, 0]),
        ])
        XCTAssertEqual(result.responses[0].parameterGradient, [-0.5, 0, 0.75])
        XCTAssertLessThan(result.responses[0].adjointBackwardError, 1e-12)
    }

    func testCheckpointedTrajectoryGradientThroughBridge() throws {
        let times = [0.0, 0.1, 0.27, 0.45, 0.7]
        let model = try scalarModel(dynamic: true)
        XCTAssertEqual(EngineeringTrajectory.isAvailable, NumericCoreAPI.supports("engineering-adjoints"))
        guard EngineeringTrajectory.isAvailable else {
            XCTAssertThrowsError(try EngineeringTrajectory(model: model, times: times))
            return
        }
        let response = EngineeringTrajectoryResponse(
            name: "response",
            running: .init(nodes: [.parameter(1), .multiply(0, 0)], output: 1),
            terminal: .init(nodes: [.parameter(1), .parameter(2), .constant(0.5),
                                    .multiply(1, 2), .add(0, 3), .parameter(5), .add(4, 5)], output: 6))
        func solve(load: Double, initial: Double) throws -> EngineeringTrajectoryAdjoints {
            let model = try scalarModel(dynamic: true, load: load)
            let trajectory = try EngineeringTrajectory(model: model, times: times, initialState: [initial],
                                                        options: .init(checkpointStride: 2))
            XCTAssertEqual(trajectory.checkpoints().map(\.step), [0, 2, 4])
            return try trajectory.adjoints([response])
        }
        let result = try solve(load: 8, initial: 0.25)
        let gradient = try XCTUnwrap(result.responses.first)
        let h = 1e-5
        let upper = try solve(load: 8 + h, initial: 0.25).responses[0].value
        let lower = try solve(load: 8 - h, initial: 0.25).responses[0].value
        XCTAssertEqual(gradient.parameterGradient[2], (upper - lower) / (2 * h), accuracy: 1e-8)
        XCTAssertEqual(result.replayedSteps, 2)
        XCTAssertEqual(result.peakSegmentStates, 3)
        XCTAssertEqual(result.transposeSolves, 4)
        XCTAssertLessThan(gradient.maximumAdjointBackwardError, 1e-12)
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
