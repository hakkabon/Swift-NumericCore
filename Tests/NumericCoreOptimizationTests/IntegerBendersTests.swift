import XCTest
import NumericCore
import NumericCoreOptimization
import NumericCoreSparse

final class IntegerBendersTests: XCTestCase {
    private func firstStage(_ cost: [Double]) throws -> SparseLinearProblem {
        try .init(objective: cost, rows: 0, columns: cost.count, rowPointers: [0], columnIndices: [],
                  values: [], rowBounds: [], variableBounds: cost.map { _ in .init(lower: 0, upper: 1) },
                  isInteger: cost.map { _ in true })
    }

    func testIntegerRecourseSelectsAPlanThroughTheBridge() throws {
        let recourse = try SparseLinearProblem(
            objective: [5], rows: 1, columns: 1, rowPointers: [0, 1], columnIndices: [0], values: [1],
            rowBounds: [.init(lower: 0.5)], variableBounds: [.init(lower: 0, upper: 1)], isInteger: [true])
        let coupling = try SparseMatrix<Double>(
            rows: 1, cols: 1, rowPointers: [0, 1], columnIndices: [0], values: [1])
        let problem = try BendersProblem(firstStage: firstStage([1]), recourse: recourse, coupling: coupling)
        XCTAssertEqual(IntegerBendersSolver.isAvailable,
                       NumericCoreAPI.supports("integer-benders-decomposition"))
        guard IntegerBendersSolver.isAvailable else {
            XCTAssertThrowsError(try IntegerBendersSolver.solve(problem)) {
                XCTAssertEqual($0 as? LPDecompositionError, .unsupportedFFI)
            }
            return
        }
        let result = try IntegerBendersSolver.solve(problem)
        XCTAssertEqual(result.termination, .converged)
        XCTAssertEqual(result.lowerBound, 1)
        XCTAssertEqual(result.upperBound, 1)
        XCTAssertEqual(result.incumbent?.firstStage, [1])
        XCTAssertEqual(result.incumbent?.recourse.first?.point, [0])
        XCTAssertGreaterThan(result.optimalityCuts, 0)

        let limited = try IntegerBendersSolver.solve(problem, options: .init(maxRecourseNodes: 1))
        XCTAssertEqual(limited.termination, .recourseNodeLimit)
        XCTAssertEqual(limited.blockingScenario, problem.scenarios.first?.id)
        XCTAssertNil(limited.incumbent)
    }

    func testSwiftOracleReceivesBinaryProjectionsAndReturnsScopedCuts() throws {
        guard IntegerBendersSolver.isAvailable else { return }
        let id = LPSubproblemID(name: "schedule", scenario: "peak")
        let problem = try IntegerBendersProblem(firstStage: firstStage([1, 2]), scenarios: [
            .logic(.init(id: id, probability: 1, binaryColumns: [0, 1], objectiveLowerBound: 0)),
        ])
        var evaluations: [[Bool]] = []
        let result = try IntegerBendersSolver.solve(problem) { scenario, bits in
            XCTAssertEqual(scenario, id)
            XCTAssertEqual(bits.count, 2)
            evaluations.append(bits)
            return bits[0] ? .optimal(objective: bits[1] ? 0 : 5, validity: [1]) : .infeasible(conflict: [0])
        }
        XCTAssertEqual(result.termination, .converged)
        XCTAssertEqual(result.incumbent?.firstStage, [1, 1])
        XCTAssertEqual(result.upperBound, 3)
        XCTAssertEqual(result.feasibilityCuts, 1)
        XCTAssertTrue(result.usesLogicOracle)
        XCTAssertEqual(evaluations.filter { !$0[0] }.count, 1)
        let unresolved = try IntegerBendersSolver.solve(problem) { _, _ in .unresolved }
        XCTAssertEqual(unresolved.termination, .oracleUnresolved)
        XCTAssertEqual(unresolved.blockingScenario, id)
        XCTAssertNil(unresolved.upperBound)
    }
}
