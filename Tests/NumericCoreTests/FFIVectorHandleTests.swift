import XCTest
@testable import NCBindings

final class FFIVectorHandleTests: XCTestCase {
    func testAxpyInPlaceUpdatesCorrectly() throws {
        let x = FFIVectorHandle([1, 1, 1])
        let y = FFIVectorHandle([1, 2, 3])
        try y.axpy(alpha: 2, x)
        XCTAssertEqual(y.toArray(), [3, 4, 5])
    }

    func testDotMatchesHandComputation() throws {
        let x = FFIVectorHandle([1, 2, 3])
        let y = FFIVectorHandle([4, 5, 6])
        XCTAssertEqual(try x.dot(y), 32)
    }

    func testNorm2MatchesHandComputation() {
        let x = FFIVectorHandle([3, 4])
        XCTAssertEqual(x.norm2(), 5)
    }

    func testCountMatchesConstruction() {
        let x = FFIVectorHandle([1, 2, 3, 4])
        XCTAssertEqual(x.count, 4)
    }

    func testAxpyRejectsDimensionMismatch() {
        let x = FFIVectorHandle([1, 1])
        let y = FFIVectorHandle([1, 2, 3])
        XCTAssertThrowsError(try y.axpy(alpha: 2, x))
    }

    func testDotRejectsDimensionMismatch() {
        let x = FFIVectorHandle([1, 1])
        let y = FFIVectorHandle([1, 2, 3])
        XCTAssertThrowsError(try x.dot(y))
    }

    func testChainedAxpyAgainstSameHandle() throws {
        // The scenario this type exists for: several in-place calls
        // against the same handle, one final read-back.
        let accumulator = FFIVectorHandle([0, 0, 0])
        let step = FFIVectorHandle([1, 1, 1])
        for _ in 0..<3 {
            try accumulator.axpy(alpha: 1, step)
        }
        XCTAssertEqual(accumulator.toArray(), [3, 3, 3])
    }

    func testFloatVariantAxpyAndDot() throws {
        let x = FFIVectorHandleFloat([1, 1, 1])
        let y = FFIVectorHandleFloat([1, 2, 3])
        try y.axpy(alpha: 2, x)
        XCTAssertEqual(y.toArray(), [3, 4, 5])
        XCTAssertEqual(try y.dot(x), 12)
    }
}
