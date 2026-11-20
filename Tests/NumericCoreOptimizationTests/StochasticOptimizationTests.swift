import Foundation
import NumericCore
import NumericCoreOptimization
import NumericCoreSparse
import XCTest

final class StochasticOptimizationTests: XCTestCase {
    private func problem() throws -> BendersProblem {
        let firstStage = try SparseLinearProblem(
            objective: [1.5], rows: 0, columns: 1, rowPointers: [0], columnIndices: [],
            values: [], rowBounds: [], variableBounds: [.init(lower: 0, upper: 10)])
        let coupling = try SparseMatrix<Double>(
            rows: 1, cols: 1, rowPointers: [0, 1], columnIndices: [0], values: [1])
        let scenarios: [BendersScenario] = try [("normal", 0.8, 2.0), ("peak", 0.2, 6.0)].map {
            name, probability, demand in
            let recourse = try SparseLinearProblem(
                objective: [4], rows: 1, columns: 1, rowPointers: [0, 1], columnIndices: [0],
                values: [1], rowBounds: [.init(lower: demand)], variableBounds: [.init(lower: 0, upper: 10)])
            return .init(id: .init(name: name), probability: probability, recourse: recourse, coupling: coupling)
        }
        return .init(firstStage: firstStage, scenarios: scenarios)
    }

    func testScenarioRiskAndBoundThroughBridge() throws {
        let tree = try ScenarioTree(twoStage: problem())
        XCTAssertEqual(StochasticOptimization.isAvailable, NumericCoreAPI.supports("stochastic-optimization"))
        guard StochasticOptimization.isAvailable else {
            XCTAssertThrowsError(try StochasticOptimization.solve(tree)) {
                XCTAssertEqual($0 as? LPDecompositionError, .unsupportedFFI)
            }
            return
        }
        let expected = try StochasticOptimization.solve(tree)
        XCTAssertEqual(expected.termination, .converged)
        XCTAssertEqual(try XCTUnwrap(expected.policy).decisions[0][0], 2, accuracy: 1e-7)
        XCTAssertEqual(try XCTUnwrap(expected.lowerBound), 6.2, accuracy: 1e-7)
        let risk = try StochasticOptimization.solve(tree, risk: .meanCvar(alpha: 0.8, weight: 1))
        XCTAssertEqual(risk.termination, .converged)
        let policy = try XCTUnwrap(risk.policy)
        XCTAssertEqual(policy.decisions[0][0], 6, accuracy: 1e-7)
        XCTAssertEqual(try XCTUnwrap(policy.conditionalValueAtRisk), 9, accuracy: 1e-7)
    }

    func testSamplingReductionAndCheckpointRoundTrip() throws {
        guard StochasticOptimization.isAvailable else { return }
        let problem = try problem()
        let indices = try StochasticOptimization.draw(weights: [0.8, 0.2], count: 10, seed: 64)
        XCTAssertEqual(indices, try StochasticOptimization.draw(weights: [0.8, 0.2], count: 10, seed: 64))
        XCTAssertEqual(try StochasticOptimization.solveSampleAverage(problem, indices: [0, 1, 1, 1])
            .termination, .converged)
        let evaluation = try StochasticOptimization.evaluate(problem, decision: [2], indices: [0, 0, 0, 1])
        XCTAssertEqual(evaluation.mean, 7, accuracy: 1e-7)
        XCTAssertEqual(evaluation.standardError, 4, accuracy: 1e-7)
        XCTAssertTrue(evaluation.confidenceInterval95.contains(evaluation.mean))
        let reduced = try StochasticOptimization.reduce(features: [[0], [1], [10]], weights: [0.4, 0.4, 0.2], keep: 2)
        XCTAssertEqual(reduced.retained.map(\.index), [1, 2])
        XCTAssertEqual(reduced.weightedDistance, 0.4, accuracy: 1e-7)

        let partial = try StochasticOptimization.hedge(problem, options: .init(rho: 1.5, maxIterations: 3))
        XCTAssertEqual(partial.termination, .iterationLimit)
        let encoded = try JSONEncoder().encode(XCTUnwrap(partial.checkpoint))
        let decoded = try JSONDecoder().decode(HedgingCheckpoint.self, from: encoded)
        let resumed = try StochasticOptimization.hedge(problem, options: .init(rho: 1.5, scenarioThreads: 2),
                                                        checkpoint: decoded)
        XCTAssertEqual(resumed.termination, .converged)
        XCTAssertEqual(try XCTUnwrap(resumed.checkpoint).consensus[0], 2, accuracy: 1e-4)
    }
}
