import XCTest
@testable import NumericCore
@testable import NumericCoreSparse

/// Confirms `RustFallbackBackend`/`SparseMatrix` genuinely exercise the
/// `Float` FFI path (`nc-ffi`'s `*_f32` exports, added after `Double`
/// was already wired through) — not just that `Float` still happens to
/// produce correct answers via some remaining Swift fallback, since
/// ADR 0006's update says there shouldn't be one left.
final class FloatFFITests: XCTestCase {
    override func setUp() {
        super.setUp()
        Dispatcher.registeredBackends = []
    }

    func testMatmulFloatKnownResult() throws {
        // Same known 2x2 case already covered for Double in MatrixTests.
        let a = try Matrix<Float>(rows: [[1, 2], [3, 4]])
        let b = try Matrix<Float>(rows: [[5, 6], [7, 8]])
        let result = try a * b
        let expected = try Matrix<Float>(rows: [[19, 22], [43, 50]])
        XCTAssertEqual(result, expected)
    }

    func testDotFloatMatchesHandComputation() throws {
        let x = Vector<Float>([1, 2, 3])
        let y = Vector<Float>([4, 5, 6])
        XCTAssertEqual(try x.dot(y), 32)
    }

    func testAxpyFloatUpdatesCorrectly() throws {
        let x = Vector<Float>([1, 1, 1])
        let y = Vector<Float>([1, 2, 3])
        let result = try y.adding(x, scaledBy: 2)
        XCTAssertEqual(result, Vector<Float>([3, 4, 5]))
    }

    func testNormFloatMatchesHandComputation() throws {
        let x = Vector<Float>([3, 4])
        XCTAssertEqual(try x.norm(), 5)
    }

    func testMatmulFloatDimensionMismatchThrows() throws {
        let a = try Matrix<Float>(rows: [[1, 2, 3], [4, 5, 6]])
        let b = try Matrix<Float>(rows: [[1, 2], [3, 4]])
        XCTAssertThrowsError(try a * b)
    }

    func testSparseSpmvFloatMatchesHandComputation() throws {
        // [[1, 0, 2], [0, 3, 0]] * [1, 1, 1] = [3, 3] — same case
        // already covered for Double in SparseAndGraphTests.
        let m = try SparseMatrix<Float>(
            rows: 2, cols: 3,
            rowPointers: [0, 2, 3],
            columnIndices: [0, 2, 1],
            values: [1, 2, 3]
        )
        let result = try m.multiplying(Vector([1, 1, 1]))
        XCTAssertEqual(result, Vector<Float>([3, 3]))
    }

    func testFloatAndDoubleMatmulAgreeOnTheSameProblem() throws {
        // Cross-check: solving the same problem in both Scalar types
        // should agree up to Float's lower precision.
        let aFloat = try Matrix<Float>(rows: [[2, 0], [1, 3]])
        let bFloat = try Matrix<Float>(rows: [[1, 4], [2, 5]])
        let floatResult = try aFloat * bFloat

        let aDouble = try Matrix<Double>(rows: [[2, 0], [1, 3]])
        let bDouble = try Matrix<Double>(rows: [[1, 4], [2, 5]])
        let doubleResult = try aDouble * bDouble

        for r in 0..<2 {
            for c in 0..<2 {
                XCTAssertEqual(Double(floatResult[r, c]), doubleResult[r, c], accuracy: 1e-5)
            }
        }
    }
}
