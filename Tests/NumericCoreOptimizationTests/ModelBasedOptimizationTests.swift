import XCTest
@testable import NumericCoreOptimization

final class ModelBasedOptimizationTests: XCTestCase {
    func testSolvesRotatedBoundedQuadratic() throws {
        let result = try ModelBasedTrustRegion.minimize(
            initial: [-2, 3],
            bounds: [.init(lower: -2, upper: 4), .init(lower: -3, upper: 3)]) { x in
                let a = x[0]-1, b = x[1]+0.5
                return 2*a*a + 1.5*a*b + 3*b*b
            }
        XCTAssertEqual(result.termination, .converged)
        XCTAssertEqual(result.point[0], 1, accuracy: 2e-4)
        XCTAssertEqual(result.point[1], -0.5, accuracy: 2e-4)
        XCTAssertLessThan(result.objective, 1e-7)
        XCTAssertGreaterThan(result.acceptedSteps, 0)
        XCTAssertGreaterThan(result.modelBuilds, 0)
    }

    func testUsesOneSidedGeometryAtBound() throws {
        let result = try ModelBasedTrustRegion.minimize(
            initial: [0], bounds: [.init(lower: 0, upper: 4)]) {
                pow($0[0]-2, 2)
            }
        XCTAssertEqual(result.point[0], 2, accuracy: 1e-5)
        XCTAssertGreaterThan(result.oneSidedStencils, 0)
    }

    func testBudgetCancellationAndInvalidFixedBoundsAreExplicit() throws {
        let limited = try ModelBasedTrustRegion.minimize(
            initial: [3], options: .init(maxEvaluations: 4)) { $0[0]*$0[0] }
        XCTAssertEqual(limited.termination, .evaluationLimit)
        let cancelled = try ModelBasedTrustRegion.minimize(initial: [3], observer: { _ in false }) {
            $0[0]*$0[0]
        }
        XCTAssertEqual(cancelled.termination, .cancelled)
        XCTAssertThrowsError(try ModelBasedTrustRegion.minimize(
            initial: [1], bounds: [.fixed(1)]) { _ in 0 })
    }
}
