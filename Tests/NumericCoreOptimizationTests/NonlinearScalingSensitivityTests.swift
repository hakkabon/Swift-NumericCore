import XCTest
@testable import NumericCoreOptimization

final class NonlinearScalingSensitivityTests: XCTestCase {
    func testEqualityRightHandSideSensitivity() throws {
        let objective = NonlinearExpression(nodes: [
            .parameter(0), .pow(0, 2), .parameter(1), .pow(2, 2), .add(1, 3)
        ], output: 4)
        let equality = NonlinearExpression(nodes: [
            .parameter(0), .parameter(1), .add(0, 1)
        ], output: 2)
        let model = try NonlinearModel.objective(parameterCount: 2,
            bounds: [.init(), .init()], expression: objective)
        let problem = try ConstrainedNonlinearProblem(model: model,
            constraints: [.init(expression: equality, bound: .init(lower: 1, upper: 1))])
        let request = NonlinearSensitivityRequest(objectiveGradientPerturbation: [0, 0],
            constraintBoundPerturbation: [1], variableBoundPerturbation: [0, 0])
        let result = try NonlinearSensitivityAnalyzer.analyze(problem: problem, point: [0.5, 0.5],
            multipliers: [.init(equality: -1)], request: request)
        XCTAssertEqual(result.pointDerivative[0], 0.5, accuracy: 1e-9)
        XCTAssertEqual(result.pointDerivative[1], 0.5, accuracy: 1e-9)
        XCTAssertLessThan(result.residualNorm, 1e-10)
        XCTAssertEqual(result.scaling.activeSet.count, 1)
    }

    func testExplicitVariableScalingEquilibratesActiveRow() throws {
        let objective = NonlinearExpression(nodes: [.parameter(0), .pow(0, 2)], output: 1)
        let row = NonlinearExpression(nodes: [.parameter(0)], output: 0)
        let model = try NonlinearModel.objective(parameterCount: 1,
            bounds: [.init()], expression: objective)
        let problem = try ConstrainedNonlinearProblem(model: model,
            constraints: [.init(expression: row, bound: .init(lower: 2, upper: 2))])
        let result = try NonlinearSensitivityAnalyzer.analyze(problem: problem, point: [2],
            multipliers: [.init(equality: -4)],
            request: .init(objectiveGradientPerturbation: [0],
                           constraintBoundPerturbation: [1], variableBoundPerturbation: [0]),
            options: .init(variableFactors: [1_000]))
        XCTAssertEqual(result.scaling.constraintFactors, [0.001])
        XCTAssertEqual(result.scaling.scaledJacobianNormRange.lower ?? .nan, 1, accuracy: 1e-12)
        XCTAssertEqual(result.pointDerivative, [1])
    }

    func testActiveVariableBoundSensitivityAndMultiplierSign() throws {
        let objective = NonlinearExpression(nodes: [
            .parameter(0), .pow(0, 2), .constant(-4), .multiply(0, 2), .add(1, 3)
        ], output: 4)
        let row = NonlinearExpression(nodes: [.parameter(0)], output: 0)
        let model = try NonlinearModel.objective(parameterCount: 1,
            bounds: [.init(lower: nil, upper: 1)], expression: objective)
        let problem = try ConstrainedNonlinearProblem(model: model,
            constraints: [.init(expression: row, bound: .init(lower: nil, upper: 10))])
        let result = try NonlinearSensitivityAnalyzer.analyze(problem: problem, point: [1],
            multipliers: [.init()], request: .init(objectiveGradientPerturbation: [0],
                constraintBoundPerturbation: [0], variableBoundPerturbation: [1]))
        XCTAssertEqual(result.pointDerivative, [1])
        XCTAssertEqual(result.variableUpperMultiplierDerivative[0], -2, accuracy: 1e-9)
        XCTAssertEqual(result.scaling.activeSet.first?.variable, 0)
    }
}
