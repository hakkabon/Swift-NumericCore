import Foundation
import NumericCore
import NumericCoreOptimization
import NumericCoreSparse
import XCTest

final class DistributedBendersTests: XCTestCase {
    private func problem() throws -> BendersProblem {
        let first = try SparseLinearProblem(objective: [1.5], rows: 0, columns: 1, rowPointers: [0],
            columnIndices: [], values: [], rowBounds: [], variableBounds: [.init(lower: 0, upper: 10)])
        let coupling = try SparseMatrix<Double>(rows: 1, cols: 1, rowPointers: [0, 1],
            columnIndices: [0], values: [1])
        let scenarios: [BendersScenario] = try [(2.0, 0.8), (6.0, 0.2)].enumerated().map { index, scenario in
            let recourse = try SparseLinearProblem(objective: [4], rows: 1, columns: 1, rowPointers: [0, 1],
                columnIndices: [0], values: [1], rowBounds: [.init(lower: scenario.0)],
                variableBounds: [.init(lower: 0, upper: 10)])
            return .init(id: .init(name: "scenario-\(index)"), probability: scenario.1, recourse: recourse, coupling: coupling)
        }
        return .init(firstStage: first, scenarios: scenarios)
    }

    func testCheckpointedDistributedSolveAndIndependentProofReplay() throws {
        let problem = try problem()
        XCTAssertEqual(DistributedBendersCoordinator.isAvailable, NumericCoreAPI.supports("distributed-benders"))
        guard DistributedBendersCoordinator.isAvailable else {
            XCTAssertThrowsError(try DistributedBendersCoordinator(problem: problem)) {
                XCTAssertEqual($0 as? DistributedBendersError, .unsupportedFFI)
            }
            return
        }
        let first = try DistributedBendersCoordinator(problem: problem, runID: "swift-test")
        let job = try XCTUnwrap(first.pendingJobs().last)
        let reply = try DistributedBendersCoordinator.executeJob(job.json)
        XCTAssertEqual(try first.submit(reply), .accepted)
        let resumed = try DistributedBendersCoordinator(problem: problem, checkpoint: first.exportCheckpoint())
        XCTAssertEqual(try resumed.pendingJobs().count, 1)
        XCTAssertEqual(try resumed.submit(reply), .duplicate)
        for _ in 0..<10 {
            if try resumed.progress().status != .awaitingReplies { break }
            for job in try resumed.pendingJobs().reversed() {
                try resumed.submit(DistributedBendersCoordinator.executeJob(job.json))
            }
        }
        let result = try resumed.progress()
        XCTAssertEqual(result.status, .converged)
        let proof = try resumed.exportProof()
        let audited = try DistributedBendersCoordinator.verify(problem: problem, proof: proof,
                                                                options: .init(lpIterationLimit: 1))
        XCTAssertEqual(audited, result.audit)
        XCTAssertEqual(audited.claim, .optimality)
        XCTAssertEqual(try XCTUnwrap(audited.lowerBound), 6.2, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(audited.incumbent).firstStage, [2])
        XCTAssertThrowsError(try DistributedBendersCoordinator.verify(problem: problem, proof: "{}"))
    }
}
