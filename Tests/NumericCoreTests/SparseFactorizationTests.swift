import XCTest
@testable import NumericCoreSparse

final class SparseFactorizationTests: XCTestCase {
    func testLUReusesSymbolicAnalysisAndSolvesMultipleRightHandSides() throws {
        let matrix = try SparseMatrix<Double>(rows: 3, cols: 3, entries: [
            .init(row: 0, column: 0, value: 4), .init(row: 0, column: 1, value: 1),
            .init(row: 1, column: 0, value: 2), .init(row: 1, column: 1, value: 5),
            .init(row: 1, column: 2, value: 1), .init(row: 2, column: 1, value: 1),
            .init(row: 2, column: 2, value: 3),
        ])
        let analysis = try SparseSymbolicAnalysis(matrix: matrix, ordering: .minimumDegree)
        let factor = try SparseLUFactorization(matrix: matrix, analysis: analysis)
        let solutions = try factor.solve([[6, 15, 11], [1, 2, 3]])
        XCTAssertEqual(solutions[0][0], 1, accuracy: 1e-12)
        XCTAssertEqual(solutions[0][1], 2, accuracy: 1e-12)
        XCTAssertEqual(solutions[0][2], 3, accuracy: 1e-12)

        let updated = try SparseMatrix<Double>(rows: 3, cols: 3, entries: [
            .init(row: 0, column: 0, value: 5), .init(row: 0, column: 1, value: 1),
            .init(row: 1, column: 0, value: 2), .init(row: 1, column: 1, value: 6),
            .init(row: 1, column: 2, value: 1), .init(row: 2, column: 1, value: 1),
            .init(row: 2, column: 2, value: 4),
        ])
        try factor.refactor(with: updated)
        let solution = try factor.solve([7, 17, 14])
        XCTAssertEqual(solution[0], 1, accuracy: 1e-12)
        XCTAssertEqual(solution[1], 2, accuracy: 1e-12)
        XCTAssertEqual(solution[2], 3, accuracy: 1e-12)
    }

    func testLDLTUsesTwoByTwoPivotAndReportsInertia() throws {
        let matrix = try SparseMatrix<Double>(rows: 2, cols: 2, entries: [
            .init(row: 0, column: 1, value: 1), .init(row: 1, column: 0, value: 1),
        ])
        let factor = try SparseLDLTFactorization(matrix: matrix, ordering: .natural)
        XCTAssertEqual(factor.inertia, SparseInertia(positive: 1, negative: 1, zero: 0))
        XCTAssertEqual(try factor.solve([2, 3]), [3, 2])
    }

    func testRefinementAndPatternValidation() throws {
        let matrix = try SparseMatrix<Double>(rows: 2, cols: 2, entries: [
            .init(row: 0, column: 0, value: 4), .init(row: 0, column: 1, value: 1),
            .init(row: 1, column: 0, value: 1), .init(row: 1, column: 1, value: 3),
        ])
        let factor = try SparseLDLTFactorization(matrix: matrix)
        let result = try factor.solveRefined([6, 7])
        XCTAssertLessThan(result.residualNorm, 1e-12)
        XCTAssertGreaterThanOrEqual(result.diagnostics.factorNonZeroCount, 2)

        let changedPattern = try SparseMatrix<Double>(rows: 2, cols: 2, entries: [
            .init(row: 0, column: 0, value: 4), .init(row: 1, column: 1, value: 3),
        ])
        XCTAssertThrowsError(try factor.refactor(with: changedPattern))
    }
}
