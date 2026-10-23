import XCTest
@testable import NumericCoreOptimization

final class FiniteDifferenceTests: XCTestCase {
    func testCentralGradientMatchesQuadratic() throws {
        let result = try FiniteDifference.centralGradient(at: [2, -3]) { point in
            point[0] * point[0] + 2 * point[1] * point[1]
        }
        XCTAssertEqual(result.gradient[0], 4, accuracy: 1e-8)
        XCTAssertEqual(result.gradient[1], -12, accuracy: 1e-8)
        XCTAssertEqual(result.evaluations, 4)
    }
}
