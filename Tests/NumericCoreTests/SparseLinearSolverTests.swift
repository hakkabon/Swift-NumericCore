import XCTest
@testable import NumericCoreSparse

final class SparseLinearSolverTests: XCTestCase {
    private func spd() throws -> SparseMatrix<Double> {
        try .init(rows: 3, cols: 3, rowPointers: [0, 2, 5, 7],
                  columnIndices: [0, 1, 0, 1, 2, 1, 2],
                  values: [4, 1, 1, 3, 1, 1, 2])
    }

    func testSparseLUAndCholeskySolveWithCertifiedResiduals() throws {
        let matrix = try spd(), rhs = [6.0, 10.0, 8.0]
        for result in [
            try SparseLinearSolver.solveLU(matrix: matrix, rhs: rhs),
            try SparseLinearSolver.solveCholesky(matrix: matrix, rhs: rhs),
        ] {
            XCTAssertEqual(result.solution[0], 1, accuracy: 1e-12)
            XCTAssertEqual(result.solution[1], 2, accuracy: 1e-12)
            XCTAssertEqual(result.solution[2], 3, accuracy: 1e-12)
            XCTAssertLessThan(result.relativeResidual, 1e-12)
            XCTAssertGreaterThanOrEqual(result.factorNonZeroCount, 3)
        }
    }

    func testIncompleteCholeskyPreconditionsCG() throws {
        let result = try SparseLinearSolver.solve(
            matrix: spd(), rhs: [6, 10, 8], method: .conjugateGradient,
            options: .init(maxIterations: 20, tolerance: 1e-12,
                           preconditioner: .incompleteCholesky))
        XCTAssertTrue(result.converged)
        XCTAssertEqual(result.iterations, 1)
        XCTAssertLessThan(result.relativeResidual, 1e-12)
    }

    func testILU0PreconditionsGMRES() throws {
        let matrix = try SparseMatrix<Double>(
            rows: 3, cols: 3, rowPointers: [0, 2, 5, 7],
            columnIndices: [0, 1, 0, 1, 2, 1, 2],
            values: [4, 1, 2, 3, 1, 1, 2])
        let result = try SparseLinearSolver.solve(
            matrix: matrix, rhs: [6, 11, 8], method: .gmres(restart: 3),
            options: .init(maxIterations: 20, tolerance: 1e-12, preconditioner: .ilu0))
        XCTAssertTrue(result.converged)
        XCTAssertEqual(result.iterations, 1)
    }

    func testDirectSolversRejectInvalidStructure() throws {
        let nonsquare = try SparseMatrix<Double>(
            rows: 1, cols: 2, rowPointers: [0, 1], columnIndices: [0], values: [1])
        XCTAssertThrowsError(try SparseLinearSolver.solveLU(matrix: nonsquare, rhs: [1]))
        let indefinite = try SparseMatrix<Double>(
            rows: 2, cols: 2, rowPointers: [0, 1, 2],
            columnIndices: [0, 1], values: [1, -1])
        XCTAssertThrowsError(try SparseLinearSolver.solveCholesky(matrix: indefinite, rhs: [1, 1]))
    }
}
