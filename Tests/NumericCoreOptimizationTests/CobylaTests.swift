import NumericCore
import NumericCoreOptimization
import XCTest

final class CobylaTests: XCTestCase {
    func testActiveNonlinearInequalityFromInfeasibleStart() throws {
        guard CobylaSolver.isAvailable else {
            XCTAssertThrowsError(try CobylaSolver.minimize(initial: [0], constraintKinds: []) { _ in
                XCTFail("The objective must not run without the COBYLA capability")
                return .init(objective: 0, constraints: [])
            }) { error in
                guard case NCError.unsupportedOperation(_) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            return
        }
        var calls = 0
        let result = try CobylaSolver.minimize(
            initial: [0, 2], constraintKinds: [.lessEqual],
            options: .init(maxEvaluations: 220, initialRadius: 0.75)
        ) { p in
            calls += 1
            let ySquared = p[1] * p[1]
            let xOffset = p[0] - 2
            return .init(objective: p[0] * p[0] + ySquared,
                         constraints: [xOffset * xOffset + ySquared - 1])
        }
        XCTAssertEqual(result.termination, .radiusReached)
        XCTAssertEqual(result.evaluations, calls)
        XCTAssertTrue(result.feasible)
        XCTAssertEqual(result.maximumViolation, max(0, result.constraintValues[0]), accuracy: 1e-14)
        XCTAssertEqual(result.point[0], 1, accuracy: 1e-5)
        XCTAssertEqual(result.point[1], 0, accuracy: 1e-4)
        XCTAssertEqual(result.objective, 1, accuracy: 1e-6)
    }

    func testFixedCoordinateBudgetAndCallbackErrors() throws {
        guard CobylaSolver.isAvailable else { throw XCTSkip("Requires the COBYLA FFI capability") }
        let limited = try CobylaSolver.minimize(
            initial: [0, 0, 0],
            bounds: [.init(), .init(), .init(lower: 0.25, upper: 0.25)],
            constraintKinds: [.equality], options: .init(maxEvaluations: 2)
        ) { p in
            XCTAssertEqual(p[2], 0.25)
            return .init(objective: p[0] + p[1], constraints: [p[0] + p[1] + p[2] - 2])
        }
        XCTAssertEqual(limited.termination, .evaluationLimit)
        XCTAssertEqual(limited.evaluations, 2)
        XCTAssertFalse(limited.feasible)
        XCTAssertEqual(limited.maximumViolation, abs(limited.constraintValues[0]))
        enum CallerError: Error { case failed }
        var calls = 0
        XCTAssertThrowsError(try CobylaSolver.minimize(initial: [0], constraintKinds: []) { _ in
            calls += 1
            throw CallerError.failed
        }) { error in
            XCTAssertEqual(error as? CallerError, .failed)
        }
        XCTAssertEqual(calls, 1)
    }
}
