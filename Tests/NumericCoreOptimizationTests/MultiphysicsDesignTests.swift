import XCTest
@testable import NumericCoreOptimization

final class MultiphysicsDesignTests: XCTestCase {
    private func model() throws -> MultiphysicsModel {
        // Coupled fields: x + a*T - p = 0, T - b*x = 0.
        let field = NonlinearExpression(nodes: [
            .parameter(1), .parameter(5), .parameter(2), .multiply(1, 2),
            .add(0, 3), .parameter(7), .subtract(4, 5),
        ], output: 6)
        let thermal = NonlinearExpression(nodes: [
            .parameter(2), .parameter(6), .parameter(1), .multiply(1, 2),
            .subtract(0, 3),
        ], output: 4)
        let engineering = try EngineeringModel(
            unknowns: [.init(name: "x", unit: "m", role: .algebraic),
                       .init(name: "T", unit: "K", role: .algebraic)],
            parameters: [.init(name: "a", unit: "1", value: 0.5),
                         .init(name: "b", unit: "1", value: 0.4),
                         .init(name: "p", unit: "N", value: 1)],
            elements: [.init(name: "coupler", kind: "field-thermal",
                ports: [.init(name: "field", unknown: 0),
                        .init(name: "thermal", unknown: 1)],
                equations: [.init(row: 0, expression: field),
                            .init(row: 1, expression: thermal)])])
        return try .init(engineeringModel: engineering,
                         disciplines: [.init(name: "field", equationRows: [0]),
                                       .init(name: "thermal", equationRows: [1])])
    }

    func testCoupledSteadySolveAndDisciplineDiagnostics() throws {
        let result = try model().solveSteady()
        XCTAssertEqual(result.termination, .convergedResidual)
        XCTAssertEqual(result.state[0], 1/1.2, accuracy: 1e-12)
        XCTAssertEqual(result.state[1], 0.4/1.2, accuracy: 1e-12)
        XCTAssertLessThan(result.disciplineResidualNorms["field"]!, 1e-12)
        XCTAssertLessThan(result.disciplineResidualNorms["thermal"]!, 1e-12)
    }

    func testAdjointDrivenBoundedDesignOptimization() throws {
        // 0.5*(x-2)^2 + 0.05*p^2, inputs=[x,T,a,b,p].
        let response = NonlinearExpression(nodes: [
            .parameter(0), .constant(2), .subtract(0, 1), .pow(2, 2),
            .constant(0.5), .multiply(3, 4), .parameter(4), .pow(6, 2),
            .constant(0.05), .multiply(7, 8), .add(5, 9),
        ], output: 10)
        let problem = try MultiphysicsDesignProblem(
            model: model(), response: response,
            designVariables: [.init(parameter: 2, bound: .init(lower: 0, upper: 5))])
        let result = try MultiphysicsDesignOptimizer.minimize(problem: problem)
        XCTAssertEqual(result.design[0], 2.0979020979, accuracy: 1e-6)
        XCTAssertEqual(result.state[0], result.design[0]/1.2, accuracy: 1e-8)
        XCTAssertLessThan(abs(result.gradient[0]), 1e-6)
        XCTAssertGreaterThan(result.coupledSolves, 1)
    }

    func testDisciplineRowsMustPartitionSystem() throws {
        let valid = try model()
        XCTAssertThrowsError(try MultiphysicsModel(
            engineeringModel: valid.engineeringModel,
            disciplines: [.init(name: "incomplete", equationRows: [0])]))
    }
}
