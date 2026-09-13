import XCTest
@testable import NumericCore
@testable import NumericCoreAccelerate

final class CholeskySolveTests: XCTestCase {
    func testSolveSPDKnownSystem() throws {
        // [[4, 1], [1, 3]] is SPD (both leading minors positive: 4 and
        // 4*3-1*1=11). Solve for b = [1, 2]: same system used in
        // nc-iterative's conjugate_gradient test on the Rust side, so
        // the expected answer (1/11, 7/11) is cross-checked there too.
        let a = try Matrix<Double>(rows: [[4, 1], [1, 3]])
        let b = Vector<Double>([1, 2])

        let x = try XCTUnwrap(try AccelerateBackend.solveSPD(a, b))
        XCTAssertEqual(x[0], 1.0 / 11.0, accuracy: 1e-9)
        XCTAssertEqual(x[1], 7.0 / 11.0, accuracy: 1e-9)
    }

    func testSolveSPDAgreesWithGeneralQRSolve() throws {
        // For a genuinely SPD system, the Cholesky fast path and the
        // general QR path should agree — this is the real correctness
        // check, independent of hand-computing an expected answer.
        let a = try Matrix<Double>(rows: [
            [6, 2, 1],
            [2, 5, 2],
            [1, 2, 4],
        ])
        let b = Vector<Double>([9, 10, 7])

        let cholesky = try XCTUnwrap(try AccelerateBackend.solveSPD(a, b))
        let qr = try XCTUnwrap(try AccelerateBackend.solve(a, b))

        for i in 0..<3 {
            XCTAssertEqual(cholesky[i], qr[i], accuracy: 1e-8, "mismatch at index \(i)")
        }
    }

    func testSolveSPDReturnsNilForIndefiniteMatrix() throws {
        // [[1, 2], [2, 1]] has eigenvalues 3 and -1 -> not positive
        // definite (also not even a case dpotrf can complete cleanly).
        let indefinite = try Matrix<Double>(rows: [[1, 2], [2, 1]])
        let b = Vector<Double>([1, 1])

        let result = try AccelerateBackend.solveSPD(indefinite, b)
        XCTAssertNil(result)
    }

    func testSolveSPDReturnsNilForNegativeDefiniteMatrix() throws {
        let negativeDefinite = try Matrix<Double>(rows: [[-4, 0], [0, -3]])
        let b = Vector<Double>([1, 1])

        let result = try AccelerateBackend.solveSPD(negativeDefinite, b)
        XCTAssertNil(result)
    }

    func testSolveSPDRejectsNonSquareMatrix() throws {
        let a = try Matrix<Double>(rows: [[1, 2, 3], [4, 5, 6]])
        let b = Vector<Double>([1, 2])
        XCTAssertThrowsError(try AccelerateBackend.solveSPD(a, b))
    }

    func testSolveSPDRejectsDimensionMismatch() throws {
        let a = try Matrix<Double>(rows: [[4, 1], [1, 3]])
        let b = Vector<Double>([1, 2, 3])
        XCTAssertThrowsError(try AccelerateBackend.solveSPD(a, b))
    }

    func testSolveSPDIdentity() throws {
        let identity = try Matrix<Double>(rows: [[1, 0], [0, 1]])
        let b = Vector<Double>([5, -2])

        let x = try XCTUnwrap(try AccelerateBackend.solveSPD(identity, b))
        XCTAssertEqual(x[0], 5, accuracy: 1e-9)
        XCTAssertEqual(x[1], -2, accuracy: 1e-9)
    }
}
