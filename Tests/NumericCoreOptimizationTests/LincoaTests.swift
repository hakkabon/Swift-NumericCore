import NumericCore
import NumericCoreOptimization
import XCTest

final class LincoaTests: XCTestCase {
    private func model() throws -> SparseLinearProblem {
        try .init(objective: [-100, 10, 0], rows: 2, columns: 3,
                  rowPointers: [0, 3, 4], columnIndices: [0, 1, 2, 0],
                  values: [1, 1, 2, 1],
                  rowBounds: [.init(lower: 8.25, upper: 10), .init(upper: 0.75)],
                  variableBounds: [.init(lower: 0), .init(lower: 0), .init(lower: 4, upper: 4)])
    }

    func testActiveRowsAndFixedCoordinate() throws {
        let problem = try model()
        guard LincoaSolver.isAvailable else {
            XCTAssertThrowsError(try LincoaSolver.minimize(initial: [0, 0.25, 4], problem: problem) { _ in
                XCTFail("The objective must not run without the LINCOA capability")
                return 0
            }) { error in
                guard case NCError.unsupportedOperation = error else {
                    return XCTFail("Unexpected error \(error)")
                }
            }
            return
        }
        var calls = 0
        let result = try LincoaSolver.minimize(initial: [0, 0.25, 9], problem: problem) { point in
            calls += 1
            XCTAssertEqual(point[2], 4)
            let dx = point[0] - 2
            let dy = point[1] - 2
            return dx * dx + dy * dy
        }
        XCTAssertEqual(result.termination, .radiusReached)
        XCTAssertEqual(result.evaluations, calls)
        XCTAssertEqual(result.point[0], 0.75, accuracy: 1e-6)
        XCTAssertEqual(result.point[1], 1.25, accuracy: 1e-6)
        XCTAssertEqual(result.objective, 2.125, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(result.maximumViolation, 1e-8)
    }

    func testBudgetAndCallbackFailure() throws {
        guard LincoaSolver.isAvailable else { throw XCTSkip("Requires the LINCOA FFI capability") }
        let problem = try model()
        let initial = [0.0, 0.25, 4.0]
        let result = try LincoaSolver.minimize(initial: initial, problem: problem,
                                               options: .init(maxEvaluations: 1)) { x in -x[0] }
        XCTAssertEqual(result.termination, .evaluationLimit)
        XCTAssertEqual(result.evaluations, 1)
        XCTAssertEqual(result.point, initial)

        struct CallbackError: Error {}
        XCTAssertThrowsError(try LincoaSolver.minimize(initial: initial, problem: problem) { _ in
            throw CallbackError()
        }) { error in
            XCTAssertTrue(error is CallbackError)
        }
    }
}
