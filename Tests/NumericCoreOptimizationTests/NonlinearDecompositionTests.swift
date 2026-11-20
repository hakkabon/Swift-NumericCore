import NumericCore
import NumericCoreOptimization
import XCTest

final class NonlinearDecompositionTests: XCTestCase {
    func testConvexRecourseInfeasibilityCutThroughBridge() throws {
        let master = try SparseLinearProblem(
            objective: [2], rows: 0, columns: 1, rowPointers: [0], columnIndices: [], values: [],
            rowBounds: [], variableBounds: [.init(lower: 0, upper: 1)], isInteger: [true])
        let block = NonlinearRecourseBlock(
            id: "capacity", sharedColumns: [0], localBounds: [.init(lower: 0, upper: 1)],
            objective: .init(nodes: [.parameter(1), .pow(0, 2)], output: 1),
            constraints: [.init(
                expression: .init(nodes: [.parameter(0), .parameter(1), .pow(1, 2), .constant(0.5),
                                          .add(2, 3), .subtract(0, 4)], output: 5),
                bound: .init(lower: 0))])
        let problem = NonlinearDecompositionProblem(master: master, blocks: [block])
        XCTAssertEqual(NonlinearDecompositionSolver.isAvailable, NumericCoreAPI.supports("nonlinear-decomposition"))
        guard NonlinearDecompositionSolver.isAvailable else {
            XCTAssertThrowsError(try NonlinearDecompositionSolver.solve(problem)) {
                XCTAssertEqual($0 as? LPDecompositionError, .unsupportedFFI)
            }
            return
        }
        let result = try NonlinearDecompositionSolver.solve(problem)
        XCTAssertEqual(result.termination, .converged)
        XCTAssertGreaterThan(result.feasibilityCuts, 0)
        XCTAssertGreaterThan(result.recourseSolves, 0)
        XCTAssertEqual(try XCTUnwrap(result.lowerBound), 2, accuracy: 1e-6)
        let incumbent = try XCTUnwrap(result.incumbent)
        XCTAssertEqual(incumbent.masterPoint, [1])
        XCTAssertEqual(incumbent.objective, 2, accuracy: 1e-6)
        XCTAssertEqual(incumbent.recourse.first?.id, "capacity")
        XCTAssertLessThanOrEqual(try XCTUnwrap(incumbent.recourse.first?.maximumViolation), 1e-8)
    }
}
