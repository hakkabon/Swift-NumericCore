import XCTest
import NumericCore
import NumericCoreOptimization
import NumericCoreSparse

final class BendersTests: XCTestCase {
    private func firstStage(cost: Double, capacity: Double) throws -> SparseLinearProblem {
        try .init(objective: [cost], rows: 0, columns: 1, rowPointers: [0], columnIndices: [],
                  values: [], rowBounds: [], variableBounds: [.init(lower: 0, upper: capacity)])
    }

    private func recourse(demand: Double, capacity: Double? = nil) throws -> SparseLinearProblem {
        try .init(objective: [4], rows: 1, columns: 1, rowPointers: [0, 1], columnIndices: [0],
                  values: [1], rowBounds: [.init(lower: demand)],
                  variableBounds: [.init(lower: 0, upper: capacity)])
    }

    private func coupling() throws -> SparseMatrix<Double> {
        try .init(rows: 1, cols: 1, rowPointers: [0, 1], columnIndices: [0], values: [1])
    }

    func testWeightedTransportMatchesBothStrategiesAndPreservesLimitEvidence() throws {
        let first = try firstStage(cost: 1.5, capacity: 10)
        let coupling = try coupling()
        let problem = try BendersProblem(firstStage: first, scenarios: [
            .init(id: .init(name: "demand", scenario: "low"), probability: 0.5,
                  recourse: recourse(demand: 2), coupling: coupling),
            .init(id: .init(name: "demand", scenario: "high"), probability: 0.5,
                  recourse: recourse(demand: 6), coupling: coupling),
        ])
        XCTAssertEqual(BendersSolver.isAvailable, NumericCoreAPI.supports("benders-decomposition"))
        guard BendersSolver.isAvailable else {
            XCTAssertThrowsError(try BendersSolver.solve(problem)) {
                XCTAssertEqual($0 as? LPDecompositionError, .unsupportedFFI)
            }
            return
        }
        for strategy in [BendersCutStrategy.single, .multi] {
            let result = try BendersSolver.solve(problem, options: .init(cutStrategy: strategy, scenarioThreads: 2))
            XCTAssertEqual(result.termination, .converged)
            XCTAssertEqual(try XCTUnwrap(result.incumbent?.objective), 9, accuracy: 1e-8)
            XCTAssertEqual(result.incumbent?.firstStage, [6])
            XCTAssertEqual(result.incumbent?.recourse.map(\.id), problem.scenarios.map(\.id))
            XCTAssertEqual(try XCTUnwrap(result.lowerBound), 9, accuracy: 1e-8)
            XCTAssertTrue(result.history.contains { $0.warmSubproblems == 2 })
        }
        let limited = try BendersSolver.solve(problem, options: .init(maxIterations: 1))
        XCTAssertEqual(limited.termination, .iterationLimit)
        XCTAssertEqual(limited.lowerBound, 0)
        XCTAssertEqual(limited.upperBound, 16)
    }

    func testFeasibilityCutMovesClassicalMasterAndDetectsInfeasibility() throws {
        guard BendersSolver.isAvailable else { return }
        let subproblem = try recourse(demand: 3, capacity: 1)
        let coupling = try coupling()
        let feasible = try BendersSolver.solve(.init(
            firstStage: firstStage(cost: 1, capacity: 10), recourse: subproblem, coupling: coupling))
        XCTAssertEqual(feasible.termination, .converged)
        XCTAssertEqual(feasible.history.first?.feasibilityCuts, 1)
        XCTAssertEqual(feasible.upperBound, 3)
        let infeasible = try BendersSolver.solve(.init(
            firstStage: firstStage(cost: 1, capacity: 1), recourse: subproblem, coupling: coupling))
        XCTAssertEqual(infeasible.termination, .infeasible)
        XCTAssertNil(infeasible.incumbent)
    }
}
