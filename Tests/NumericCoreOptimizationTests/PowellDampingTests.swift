import XCTest
@testable import NumericCoreOptimization

final class PowellDampingTests: XCTestCase {
    func testNegativeCurvatureRetainsTheUnaffectedDirection() {
        var hessian = [[4.0, 0], [0, 3.0]]
        sqpBFGS(&hessian, [1, 0], [-2, 0], 1e-9)
        XCTAssertEqual(hessian[0][0], 0.8, accuracy: 1e-12)
        XCTAssertEqual(hessian[1][1], 3)
    }
}
