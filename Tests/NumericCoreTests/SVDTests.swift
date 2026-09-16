import XCTest
@testable import NumericCore
@testable import NumericCoreAccelerate

final class SVDTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Dispatcher.registeredBackends = []
    }

    func testSingularValuesOfDiagonalMatrix() throws {
        // A diagonal matrix's singular values are the absolute values
        // of its diagonal entries, in descending order.
        let a = try Matrix<Double>(rows: [[3, 0], [0, 1]])
        let factorization = try AccelerateBackend.svd(a)
        XCTAssertEqual(factorization.singularValues[0], 3, accuracy: 1e-9)
        XCTAssertEqual(factorization.singularValues[1], 1, accuracy: 1e-9)
    }

    func testReconstructionMatchesOriginal() throws {
        // A = U * diag(S) * Vt should recover the original matrix.
        let a = try Matrix<Double>(rows: [[1, 2], [3, 4], [5, 6]])
        let factorization = try AccelerateBackend.svd(a)

        let k = factorization.singularValues.count
        var sigma = Matrix<Double>(rows: k, cols: k, repeating: 0)
        for i in 0..<k { sigma[i, i] = factorization.singularValues[i] }

        let reconstructed = try factorization.u * sigma * factorization.vt

        for r in 0..<a.rows {
            for c in 0..<a.cols {
                XCTAssertEqual(reconstructed[r, c], a[r, c], accuracy: 1e-8, "mismatch at (\(r), \(c))")
            }
        }
    }

    func testPseudoInverseOfFullRankSquareMatrixMatchesRegularInverse() throws {
        let a = try Matrix<Double>(rows: [[4, 1], [1, 3]])
        let pinv = try AccelerateBackend.pseudoInverse(a)
        let inv = try XCTUnwrap(try AccelerateBackend.inverse(a))

        for r in 0..<2 {
            for c in 0..<2 {
                XCTAssertEqual(pinv[r, c], inv[r, c], accuracy: 1e-8)
            }
        }
    }

    func testPseudoInverseSatisfiesMoorePenroseProperty() throws {
        // A * A+ * A == A holds for any matrix, rank-deficient or not.
        let a = try Matrix<Double>(rows: [[1, 2], [2, 4], [3, 6]]) // rank 1
        let pinv = try AccelerateBackend.pseudoInverse(a)
        let reconstructed = try a * pinv * a

        for r in 0..<a.rows {
            for c in 0..<a.cols {
                XCTAssertEqual(reconstructed[r, c], a[r, c], accuracy: 1e-7)
            }
        }
    }

    func testRankOfFullRankMatrix() throws {
        let a = try Matrix<Double>(rows: [[1, 0], [0, 1]])
        XCTAssertEqual(try AccelerateBackend.rank(a), 2)
    }

    func testRankOfRankDeficientMatrix() throws {
        // Second column is a multiple of the first -> rank 1.
        let a = try Matrix<Double>(rows: [[1, 2], [2, 4], [3, 6]])
        XCTAssertEqual(try AccelerateBackend.rank(a), 1)
    }

    func testLeastSquaresSVDAgreesWithQRForFullRankSystem() throws {
        let design = try Matrix<Double>(rows: [[1, 0], [1, 1], [1, 2], [1, 3]])
        let response = Vector<Double>([1, 3, 5, 7])

        let svdResult = try AccelerateBackend.leastSquaresSVD(design: design, response: response)
        let qrResult = try XCTUnwrap(try AccelerateBackend.leastSquares(design: design, response: response))

        XCTAssertEqual(svdResult[0], qrResult[0], accuracy: 1e-7)
        XCTAssertEqual(svdResult[1], qrResult[1], accuracy: 1e-7)
    }

    func testLeastSquaresSVDSucceedsWhereQRReturnsNil() throws {
        // Rank-deficient design (second column = 2x first): QR's
        // leastSquares returns nil; the SVD path still produces the
        // minimum-norm solution.
        let design = try Matrix<Double>(rows: [[1, 2], [2, 4], [3, 6]])
        let response = Vector<Double>([1, 2, 3])

        let qrResult = try AccelerateBackend.leastSquares(design: design, response: response)
        XCTAssertNil(qrResult)

        let svdResult = try AccelerateBackend.leastSquaresSVD(design: design, response: response)
        // Minimum-norm solution to x + 2y = 1 (the consistent system
        // here) lies along the direction (1, 2)/5 scaled so that
        // x + 2y = 1 -> (1/5, 2/5).
        XCTAssertEqual(svdResult[0], 1.0 / 5.0, accuracy: 1e-6)
        XCTAssertEqual(svdResult[1], 2.0 / 5.0, accuracy: 1e-6)
    }

    func testLeastSquaresSVDRejectsDimensionMismatch() throws {
        let design = try Matrix<Double>(rows: [[1, 2], [3, 4]])
        let response = Vector<Double>([1, 2, 3])
        XCTAssertThrowsError(try AccelerateBackend.leastSquaresSVD(design: design, response: response))
    }

    func testSVDOfWideMatrix() throws {
        // m < n case: k = min(m, n) = m.
        let a = try Matrix<Double>(rows: [[1, 2, 3], [4, 5, 6]])
        let factorization = try AccelerateBackend.svd(a)
        XCTAssertEqual(factorization.singularValues.count, 2)
        XCTAssertEqual(factorization.u.rows, 2)
        XCTAssertEqual(factorization.u.cols, 2)
        XCTAssertEqual(factorization.vt.rows, 2)
        XCTAssertEqual(factorization.vt.cols, 3)
    }
}
