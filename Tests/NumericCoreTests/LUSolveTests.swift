import XCTest
@testable import NumericCore
@testable import NumericCoreAccelerate

final class LUSolveTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Dispatcher.registeredBackends = []
    }

    func testSolveLUKnownNonSymmetricSystem() throws {
        // [[2, 1], [1, 1]] x = [3, 2] -> x = [1, 1] — deliberately
        // non-symmetric-looking in general (this particular 2x2 happens
        // to be symmetric; see the next test for a genuinely
        // non-symmetric case that solveSPD couldn't handle at all).
        let a = try Matrix<Double>(rows: [[2, 1], [1, 1]])
        let b = Vector<Double>([3, 2])

        let x = try XCTUnwrap(try AccelerateBackend.solveLU(a, b))
        XCTAssertEqual(x[0], 1.0, accuracy: 1e-9)
        XCTAssertEqual(x[1], 1.0, accuracy: 1e-9)
    }

    func testSolveLUNonSymmetricMatrix() throws {
        // Genuinely non-symmetric: solveSPD would be the wrong tool
        // here (and would produce garbage without erroring, per that
        // function's documented caveat) — this is exactly the case
        // solveLU exists for.
        let a = try Matrix<Double>(rows: [[1, 2], [3, 4]])
        let b = Vector<Double>([5, 6])

        let x = try XCTUnwrap(try AccelerateBackend.solveLU(a, b))
        // Solve by hand: x = A^-1 b = [-4, 4.5]
        XCTAssertEqual(x[0], -4.0, accuracy: 1e-9)
        XCTAssertEqual(x[1], 4.5, accuracy: 1e-9)
    }

    func testSolveLUAgreesWithGeneralQRSolveOnSPDSystem() throws {
        // For an SPD system, all three solve paths should agree.
        let a = try Matrix<Double>(rows: [[4, 1], [1, 3]])
        let b = Vector<Double>([1, 2])

        let lu = try XCTUnwrap(try AccelerateBackend.solveLU(a, b))
        let qr = try XCTUnwrap(try AccelerateBackend.solve(a, b))
        let cholesky = try XCTUnwrap(try AccelerateBackend.solveSPD(a, b))

        for i in 0..<2 {
            XCTAssertEqual(lu[i], qr[i], accuracy: 1e-8)
            XCTAssertEqual(lu[i], cholesky[i], accuracy: 1e-8)
        }
    }

    func testSolveLUReturnsNilForSingularMatrix() throws {
        let singular = try Matrix<Double>(rows: [[1, 2], [2, 4]])
        let b = Vector<Double>([1, 2])
        XCTAssertNil(try AccelerateBackend.solveLU(singular, b))
    }

    func testSolveLURejectsNonSquareMatrix() throws {
        let a = try Matrix<Double>(rows: [[1, 2, 3], [4, 5, 6]])
        let b = Vector<Double>([1, 2])
        XCTAssertThrowsError(try AccelerateBackend.solveLU(a, b))
    }

    func testSolveLURejectsDimensionMismatch() throws {
        let a = try Matrix<Double>(rows: [[1, 2], [3, 4]])
        let b = Vector<Double>([1, 2, 3])
        XCTAssertThrowsError(try AccelerateBackend.solveLU(a, b))
    }

    func testSolveLUIdentity() throws {
        let identity = try Matrix<Double>(rows: [[1, 0], [0, 1]])
        let b = Vector<Double>([7, -3])
        let x = try XCTUnwrap(try AccelerateBackend.solveLU(identity, b))
        XCTAssertEqual(x[0], 7, accuracy: 1e-9)
        XCTAssertEqual(x[1], -3, accuracy: 1e-9)
    }

    func testInverseKnownMatrix() throws {
        // [[1, 2], [3, 4]]^-1 = [[-2, 1], [1.5, -0.5]]
        let a = try Matrix<Double>(rows: [[1, 2], [3, 4]])
        let inv = try XCTUnwrap(try AccelerateBackend.inverse(a))

        XCTAssertEqual(inv[0, 0], -2.0, accuracy: 1e-9)
        XCTAssertEqual(inv[0, 1], 1.0, accuracy: 1e-9)
        XCTAssertEqual(inv[1, 0], 1.5, accuracy: 1e-9)
        XCTAssertEqual(inv[1, 1], -0.5, accuracy: 1e-9)
    }

    func testInverseTimesOriginalIsIdentity() throws {
        let a = try Matrix<Double>(rows: [[4, 1], [1, 3]])
        let inv = try XCTUnwrap(try AccelerateBackend.inverse(a))
        let product = try a * inv

        XCTAssertEqual(product[0, 0], 1.0, accuracy: 1e-8)
        XCTAssertEqual(product[0, 1], 0.0, accuracy: 1e-8)
        XCTAssertEqual(product[1, 0], 0.0, accuracy: 1e-8)
        XCTAssertEqual(product[1, 1], 1.0, accuracy: 1e-8)
    }

    func testInverseReturnsNilForSingularMatrix() throws {
        let singular = try Matrix<Double>(rows: [[1, 2], [2, 4]])
        XCTAssertNil(try AccelerateBackend.inverse(singular))
    }

    func testInverseRejectsNonSquareMatrix() throws {
        let a = try Matrix<Double>(rows: [[1, 2, 3], [4, 5, 6]])
        XCTAssertThrowsError(try AccelerateBackend.inverse(a))
    }
}
