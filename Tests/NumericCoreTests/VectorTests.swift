import XCTest
@testable import NumericCore

final class VectorTests: XCTestCase {
    func testDotProduct() throws {
        let x = Vector<Double>([1, 2, 3])
        let y = Vector<Double>([4, 5, 6])
        let result = try x.dot(y)
        XCTAssertEqual(result, 32)
    }

    func testDotDimensionMismatchThrows() {
        let x = Vector<Double>([1, 2])
        let y = Vector<Double>([1, 2, 3])
        XCTAssertThrowsError(try x.dot(y))
    }

    func testNormL2() throws {
        let x = Vector<Double>([3, 4])
        let result = try x.norm()
        XCTAssertEqual(result, 5)
    }

    func testAxpyAddingProducesNewVector() throws {
        let x = Vector<Double>([1, 1, 1])
        let y = Vector<Double>([1, 2, 3])
        let result = try y.adding(x, scaledBy: 2)
        XCTAssertEqual(result, Vector<Double>([3, 4, 5]))
        // Original untouched — adding(_:scaledBy:) is non-mutating.
        XCTAssertEqual(y, Vector<Double>([1, 2, 3]))
    }
}
