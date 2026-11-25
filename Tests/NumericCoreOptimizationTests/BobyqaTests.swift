import NumericCore
import NumericCoreOptimization
import XCTest

final class BobyqaTests: XCTestCase {
    func testRotatedQuadraticWithActiveBound() throws {
        guard BobyqaSolver.isAvailable else {
            XCTAssertThrowsError(try BobyqaSolver.minimize(initial: [0], bounds: [.init()]) { _ in
                XCTFail("The objective must not run without the BOBYQA capability")
                return 0
            }) { error in
                guard case NCError.unsupportedOperation(_) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            return
        }
        var calls = 0
        let result = try BobyqaSolver.minimize(
            initial: [-3, 2], bounds: [.init(lower: -4, upper: 1), .init(lower: -4, upper: 4)],
            options: .init(maxEvaluations: 80)
        ) { p in
            calls += 1
            XCTAssertTrue((-4...1).contains(p[0]))
            XCTAssertTrue((-4...4).contains(p[1]))
            let a = p[0] + p[1] - 2
            let b = p[0] - p[1] - 1
            return a * a + 3 * b * b
        }
        XCTAssertEqual(result.termination, .radiusReached)
        XCTAssertEqual(result.evaluations, calls)
        XCTAssertLessThanOrEqual(calls, 80)
        XCTAssertEqual(result.point[0], 1)
        XCTAssertEqual(result.point[1], 0.25, accuracy: 1e-5)
        XCTAssertEqual(result.objective, 0.75, accuracy: 1e-9)
    }

    func testFixedCoordinateSmallBudgetAndThrowingObjective() throws {
        guard BobyqaSolver.isAvailable else { throw XCTSkip("Requires the BOBYQA FFI capability") }
        let bounds: [ParameterBound] = [.init(lower: 0, upper: 0.02), .init(lower: 7, upper: 7)]
        let limited = try BobyqaSolver.minimize(initial: [5, 2], bounds: bounds,
                                               options: .init(maxEvaluations: 2)) { point in
            XCTAssertEqual(point[1], 7)
            XCTAssertTrue((0...0.02).contains(point[0]))
            return (point[0] - 0.007) * (point[0] - 0.007)
        }
        XCTAssertEqual(limited.evaluations, 2)
        XCTAssertEqual(limited.termination, .evaluationLimit)

        enum ObjectiveError: Error { case fixture }
        var calls = 0
        XCTAssertThrowsError(try BobyqaSolver.minimize(initial: [5, 2], bounds: bounds) { _ in
            calls += 1
            throw ObjectiveError.fixture
        }) { error in
            XCTAssertEqual(error as? ObjectiveError, .fixture)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try BobyqaSolver.minimize(initial: [0], bounds: [.init()]) { _ in .nan })
    }
}
