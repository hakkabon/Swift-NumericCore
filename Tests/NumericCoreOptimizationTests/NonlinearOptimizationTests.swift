import XCTest
@testable import NumericCoreOptimization

final class NonlinearOptimizationTests: XCTestCase {
    func testLBFGSMinimizesRosenbrock() throws {
        let result = try LBFGS.minimize(initial: [-1.2, 1]) { x in
            let a = x[1] - x[0] * x[0]
            let b = 1 - x[0]
            return (100 * a * a + b * b, [-400 * x[0] * a - 2 * b, 200 * a])
        }
        XCTAssertEqual(result.point[0], 1, accuracy: 1e-5)
        XCTAssertEqual(result.point[1], 1, accuracy: 1e-5)
        XCTAssertLessThan(result.objective, 1e-12)
        XCTAssertGreaterThan(result.evaluations, result.iterations)
    }

    func testNonlinearLeastSquaresFitsExponentialCurve() throws {
        let xs = [0.0, 0.5, 1.0, 1.5, 2.0]
        let ys = xs.map { 2.5 * exp(-0.7 * $0) }
        let result = try NonlinearLeastSquares.solve(initial: [1, -0.1]) { parameters in
            var residuals: [Double] = []
            var jacobian: [[Double]] = []
            for (x, y) in zip(xs, ys) {
                let exponential = exp(parameters[1] * x)
                residuals.append(parameters[0] * exponential - y)
                jacobian.append([exponential, parameters[0] * x * exponential])
            }
            return .init(residuals: residuals, jacobian: jacobian)
        }
        XCTAssertEqual(result.point[0], 2.5, accuracy: 1e-6)
        XCTAssertEqual(result.point[1], -0.7, accuracy: 1e-6)
        XCTAssertLessThan(result.cost, 1e-18)
    }

    func testSolversRejectMalformedDerivativeOutput() throws {
        XCTAssertThrowsError(try LBFGS.minimize(initial: [0]) { _ in (0, []) })
        XCTAssertThrowsError(try NonlinearLeastSquares.solve(initial: [0]) { _ in
            .init(residuals: [1], jacobian: [[]])
        })
    }
}
