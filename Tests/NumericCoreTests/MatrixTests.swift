import XCTest
@testable import NumericCore

final class MatrixTests: XCTestCase {
    func testColumnMajorSubscript() throws {
        // [[1, 3],
        //  [2, 4]]  stored column-major as [1, 2, 3, 4]
        let m = try Matrix<Double>(rows: 2, cols: 2, storage: [1, 2, 3, 4])
        XCTAssertEqual(m[0, 0], 1)
        XCTAssertEqual(m[1, 0], 2)
        XCTAssertEqual(m[0, 1], 3)
        XCTAssertEqual(m[1, 1], 4)
    }

    func testInitRejectsWrongStorageCount() {
        XCTAssertThrowsError(try Matrix<Double>(rows: 2, cols: 2, storage: [1, 2, 3]))
    }

    func testMatmulIdentity() throws {
        let identity = try Matrix<Double>(rows: 2, cols: 2, storage: [1, 0, 0, 1])
        let a = try Matrix<Double>(rows: 2, cols: 2, storage: [1, 2, 3, 4])
        let result = try identity * a
        XCTAssertEqual(result, a)
    }

    func testMatmulDimensionMismatchThrows() throws {
        let a = try Matrix<Double>(rows: 2, cols: 3, storage: [1, 2, 3, 4, 5, 6])
        let b = try Matrix<Double>(rows: 2, cols: 2, storage: [1, 2, 3, 4])
        XCTAssertThrowsError(try a * b) { error in
            guard case NCError.dimensionMismatch = error else {
                return XCTFail("expected dimensionMismatch, got \(error)")
            }
        }
    }

    func testMatmulKnownResult() throws {
        // [[1, 2],   [[5, 6],   [[19, 22],
        //  [3, 4]] *  [7, 8]] =  [43, 50]]
        let a = try Matrix<Double>(rows: 2, cols: 2, storage: [1, 3, 2, 4]) // col-major
        let b = try Matrix<Double>(rows: 2, cols: 2, storage: [5, 7, 6, 8]) // col-major
        let result = try a * b
        let expected = try Matrix<Double>(rows: 2, cols: 2, storage: [19, 43, 22, 50])
        XCTAssertEqual(result, expected)
    }
}
