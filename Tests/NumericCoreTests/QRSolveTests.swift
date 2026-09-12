import XCTest
@testable import NumericCore
@testable import NumericCoreAccelerate

final class QRSolveTests: XCTestCase {
    func testSolveKnownSquareSystem() throws {
        // [[2, 1], [1, 3]] x = [3, 5]  ->  x = [4/5, 7/5]
        let a = try Matrix<Double>(rows: [[2, 1], [1, 3]])
        let b = Vector<Double>([3, 5])

        let x = try AccelerateBackend.solve(a, b)
        let solution = try XCTUnwrap(x, "expected a solution for a well-conditioned system")

        XCTAssertEqual(solution[0], 4.0 / 5.0, accuracy: 1e-9)
        XCTAssertEqual(solution[1], 7.0 / 5.0, accuracy: 1e-9)
    }

    func testSolveIdentityIsNoOp() throws {
        let identity = try Matrix<Double>(rows: [[1, 0], [0, 1]])
        let b = Vector<Double>([7, -3])

        let x = try XCTUnwrap(try AccelerateBackend.solve(identity, b))
        XCTAssertEqual(x[0], 7, accuracy: 1e-9)
        XCTAssertEqual(x[1], -3, accuracy: 1e-9)
    }

    func testSolveReturnsNilForSingularMatrix() throws {
        // Row 2 is a multiple of row 1 -> singular.
        let singular = try Matrix<Double>(rows: [[1, 2], [2, 4]])
        let b = Vector<Double>([1, 2])

        let result = try AccelerateBackend.solve(singular, b)
        XCTAssertNil(result)
    }

    func testSolveRejectsNonSquareMatrix() throws {
        let a = try Matrix<Double>(rows: [[1, 2, 3], [4, 5, 6]])
        let b = Vector<Double>([1, 2])
        XCTAssertThrowsError(try AccelerateBackend.solve(a, b))
    }

    func testLeastSquaresFitsExactLinearData() throws {
        // y = 2x + 1, sampled exactly at x = 0, 1, 2, 3 -> should
        // recover [intercept, slope] = [1, 2] exactly (up to tolerance).
        let design = try Matrix<Double>(rows: [
            [1, 0],
            [1, 1],
            [1, 2],
            [1, 3],
        ])
        let response = Vector<Double>([1, 3, 5, 7])

        let coefficients = try XCTUnwrap(try AccelerateBackend.leastSquares(design: design, response: response))
        XCTAssertEqual(coefficients[0], 1.0, accuracy: 1e-9) // intercept
        XCTAssertEqual(coefficients[1], 2.0, accuracy: 1e-9) // slope
    }

    func testLeastSquaresFitsNoisyLinearData() throws {
        // y ~= 2x + 1 with small perturbations — check the fit is close,
        // not exact, and confirm the residual is small.
        let design = try Matrix<Double>(rows: [
            [1, 0],
            [1, 1],
            [1, 2],
            [1, 3],
            [1, 4],
        ])
        let response = Vector<Double>([1.1, 2.9, 5.05, 6.9, 9.1])

        let coefficients = try XCTUnwrap(try AccelerateBackend.leastSquares(design: design, response: response))
        XCTAssertEqual(coefficients[0], 1.0, accuracy: 0.2)
        XCTAssertEqual(coefficients[1], 2.0, accuracy: 0.1)
    }

    func testLeastSquaresReturnsNilForRankDeficientDesign() throws {
        // Second column is a multiple of the first -> rank 1, not 2.
        let design = try Matrix<Double>(rows: [
            [1, 2],
            [2, 4],
            [3, 6],
        ])
        let response = Vector<Double>([1, 2, 3])

        let result = try AccelerateBackend.leastSquares(design: design, response: response)
        XCTAssertNil(result)
    }

    func testLeastSquaresRejectsUnderdeterminedDesign() throws {
        // rows < cols is out of scope (LOESS's local design matrices are
        // always overdetermined or square) and should throw, not silently
        // do something questionable.
        let design = try Matrix<Double>(rows: [[1, 2, 3]])
        let response = Vector<Double>([1])
        XCTAssertThrowsError(try AccelerateBackend.leastSquares(design: design, response: response))
    }

    func testMatrixRowMajorInitAndRoundTrip() throws {
        let m = try Matrix<Double>(rows: [[1, 2, 3], [4, 5, 6]])
        XCTAssertEqual(m.rows, 2)
        XCTAssertEqual(m.cols, 3)
        XCTAssertEqual(m[0, 0], 1)
        XCTAssertEqual(m[0, 2], 3)
        XCTAssertEqual(m[1, 0], 4)
        XCTAssertEqual(m.rowMajorArray, [[1, 2, 3], [4, 5, 6]])
    }

    func testMatrixRowMajorInitRejectsRaggedRows() {
        XCTAssertThrowsError(try Matrix<Double>(rows: [[1, 2], [3]]))
    }
}
