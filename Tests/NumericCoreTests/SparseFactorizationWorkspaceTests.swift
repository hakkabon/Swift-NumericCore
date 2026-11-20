import NumericCore
import NumericCoreSparse
import XCTest

final class SparseFactorizationWorkspaceTests: XCTestCase {
    private func matrix(_ values: [Double]) throws -> SparseMatrix<Double> {
        try SparseMatrix(rows: 2, cols: 2, rowPointers: [0, 2, 4],
                         columnIndices: [0, 1, 0, 1], values: values)
    }

    func testRustPlanAndPivotedTransposeBatch() throws {
        let input = try matrix([0, 2, 3, 4])
        XCTAssertEqual(SparseFactorizationPlan.isAvailable, NumericCoreAPI.supports("sparse-solver-workspaces"))
        guard SparseFactorizationPlan.isAvailable else {
            XCTAssertThrowsError(try SparseFactorizationPlan(matrix: input))
            return
        }
        let plan = try SparseFactorizationPlan(matrix: input)
        XCTAssertEqual(plan.inversePermutation.count, 2)
        let factor = try plan.factor(matrix: input, method: .lu)
        let batch = try factor.solveRefined([[6, 10], [-3, -2]], orientation: .transpose)
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(batch[0].solution[0], 1, accuracy: 1e-12)
        XCTAssertEqual(batch[0].solution[1], 2, accuracy: 1e-12)
        XCTAssertEqual(batch[1].solution[0], 1, accuracy: 1e-12)
        XCTAssertEqual(batch[1].solution[1], -1, accuracy: 1e-12)
        XCTAssertLessThan(batch[0].backwardError, 1e-12)
        XCTAssertGreaterThan(try factor.status().diagnostics.interchangeCount, 0)
        XCTAssertThrowsError(try factor.solve([1]))
    }

    func testSharedPlanCholeskyRefactorAndLDLTInertia() throws {
        guard SparseFactorizationPlan.isAvailable else { return }
        let original = try matrix([4, 1, 1, 3])
        let indefinite = try matrix([0, 2, 2, 0])
        let plan = try SparseFactorizationPlan(matrix: original)
        let cholesky = try plan.factor(matrix: original, method: .cholesky)
        try cholesky.refactor(values: [5, 1, 1, 4])
        let result = try cholesky.solveRefined([7, 9])
        XCTAssertEqual(result.solution[0], 1, accuracy: 1e-12)
        XCTAssertEqual(result.solution[1], 2, accuracy: 1e-12)
        XCTAssertThrowsError(try cholesky.refactor(with: indefinite))
        XCTAssertThrowsError(try cholesky.refactor(values: [5, 1]))
        XCTAssertEqual(try cholesky.solveRefined([7, 9]), result)

        let ldlt = try plan.factor(matrix: indefinite, method: .ldlt)
        XCTAssertEqual(try ldlt.status().inertia, .init(positive: 1, negative: 1, zero: 0))
        XCTAssertEqual(try ldlt.solve([4, 2]), [1, 2])
    }
}
