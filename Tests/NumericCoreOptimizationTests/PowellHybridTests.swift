import NumericCore
import NumericCoreOptimization
import XCTest

final class PowellHybridTests: XCTestCase {
    func testCallbackSolveAndAvailability() throws {
        guard NonlinearSystemSolver.isPowellHybridAvailable else {
            XCTAssertThrowsError(try NonlinearSystemSolver.solvePowellHybrid(
                initial: [0], residual: { _ in
                    XCTFail("Unavailable solver invoked a callback")
                    return [1]
                }, jacobian: { _ in [[1]] }
            )) { error in
                guard case NCError.unsupportedOperation = error else {
                    return XCTFail("Unexpected error \(error)")
                }
            }
            return
        }
        var residualCalls = 0
        var jacobianCalls = 0
        let result = try NonlinearSystemSolver.solvePowellHybrid(
            initial: [-1.2, 1],
            residual: { x in
                residualCalls += 1
                return [10 * (x[1] - x[0] * x[0]), 1 - x[0]]
            },
            jacobian: { x in
                jacobianCalls += 1
                return [[-20 * x[0], 10], [-1, 0]]
            }
        )
        XCTAssertEqual(result.termination, .convergedResidual)
        XCTAssertEqual(result.point[0], 1, accuracy: 1e-8)
        XCTAssertEqual(result.point[1], 1, accuracy: 1e-8)
        XCTAssertLessThanOrEqual(result.residualNorm, 1e-9)
        XCTAssertEqual(result.residualEvaluations, residualCalls)
        XCTAssertEqual(result.jacobianEvaluations, jacobianCalls)
        XCTAssertGreaterThan(result.rankOneUpdates, 0)
    }

    func testGraphStallBudgetAndOriginalErrors() throws {
        guard NonlinearSystemSolver.isPowellHybridAvailable else {
            throw XCTSkip("Requires the Powell hybrid FFI capability")
        }
        let model = try NonlinearEquationModel(parameterCount: 1, equations: [
            .init(nodes: [.parameter(0), .multiply(0, 0), .constant(2), .subtract(1, 2)], output: 3),
        ])
        let result = try NonlinearSystemSolver.solvePowellHybrid(model: model, initial: [1])
        XCTAssertEqual(result.termination, .convergedResidual)
        XCTAssertEqual(result.point[0], 2.squareRoot(), accuracy: 1e-8)

        let stalled = try NonlinearSystemSolver.solvePowellHybrid(model: model, initial: [0])
        XCTAssertEqual(stalled.termination, .stalled)
        XCTAssertEqual(stalled.residualNorm, 2)

        let limited = try NonlinearSystemSolver.solvePowellHybrid(
            initial: [0], options: .init(maxResidualEvaluations: 1),
            residual: { _ in [-1] },
            jacobian: { _ in
                XCTFail("The budget should terminate the solve before a Jacobian refresh")
                return [[1]]
            }
        )
        XCTAssertEqual(limited.termination, .evaluationLimit)
        XCTAssertEqual(limited.residualEvaluations, 1)

        struct CallbackError: Error {}
        XCTAssertThrowsError(try NonlinearSystemSolver.solvePowellHybrid(
            initial: [0], residual: { _ in [1] }, jacobian: { _ in throw CallbackError() }
        )) { XCTAssertTrue($0 is CallbackError) }
        XCTAssertThrowsError(try NonlinearSystemSolver.solvePowellHybrid(
            initial: [0], residual: { _ in throw CallbackError() }, jacobian: { _ in [[1]] }
        )) { XCTAssertTrue($0 is CallbackError) }
    }
}
