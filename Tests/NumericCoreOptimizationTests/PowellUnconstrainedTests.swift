import NumericCore
import NumericCoreOptimization
import XCTest

final class PowellUnconstrainedTests: XCTestCase {
    private typealias Solve = ([Double], PowellUnconstrainedOptions, @escaping ([Double]) throws -> Double)
        throws -> PowellUnconstrainedResult

    func testNewuoaAcrossFFIVersions() throws {
        try checkSolver(NewuoaSolver.minimize, available: NewuoaSolver.isAvailable)
    }

    func testUobyqaAcrossFFIVersions() throws {
        try checkSolver(UobyqaSolver.minimize, available: UobyqaSolver.isAvailable)
    }

    private func checkSolver(_ minimize: Solve, available: Bool) throws {
        guard available else {
            XCTAssertThrowsError(try minimize([0, 0], .init()) { _ in
                XCTFail("Unavailable solver invoked its objective")
                return 0
            }) { error in
                guard case NCError.unsupportedOperation = error else {
                    return XCTFail("Unexpected error \(error)")
                }
            }
            return
        }

        var calls = 0
        let result = try minimize([0, 0], .init()) { x in
            calls += 1
            let a = x[0] - 2
            let b = x[1] + 1
            return (a + b) * (a + b) + b * b
        }
        XCTAssertEqual(result.termination, .radiusReached)
        XCTAssertEqual(result.evaluations, calls)
        XCTAssertEqual(result.point[0], 2, accuracy: 1e-6)
        XCTAssertEqual(result.point[1], -1, accuracy: 1e-6)
        XCTAssertLessThan(result.objective, 1e-12)

        calls = 0
        let limited = try minimize([0, 0], .init(maxEvaluations: 2)) { x in
            calls += 1
            return -x[0]
        }
        XCTAssertEqual(limited.termination, .evaluationLimit)
        XCTAssertEqual(limited.evaluations, 2)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(limited.point, [1, 0])
        XCTAssertEqual(limited.objective, -1)

        struct CallbackError: Error {}
        XCTAssertThrowsError(try minimize([0, 0], .init()) { _ in throw CallbackError() }) {
            XCTAssertTrue($0 is CallbackError)
        }
    }
}
