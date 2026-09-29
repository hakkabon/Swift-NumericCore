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
        XCTAssertLessThan(result.gradientNorm, 1e-5)
        XCTAssertNotNil(result.acceptedStep)
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
        XCTAssertGreaterThan(result.acceptedSteps, 0)
        XCTAssertTrue(result.finalDamping.isFinite)
    }

    func testSolversRejectMalformedDerivativeOutput() throws {
        XCTAssertThrowsError(try LBFGS.minimize(initial: [0]) { _ in (0, []) })
        XCTAssertThrowsError(try NonlinearLeastSquares.solve(initial: [0]) { _ in
            .init(residuals: [1], jacobian: [[]])
        })
    }


    func testDerivativeChecksMatchSharedRosenbrockAndExponentialCases() throws {
        let point = [-1.2, 1.0]
        let gradient = try DerivativeCheck.gradient(
            at: point, analytic: [-215.6, -88.0]
        ) { x in
            100 * pow(x[1] - x[0] * x[0], 2) + pow(1 - x[0], 2)
        }
        XCTAssertTrue(gradient.passed)
        XCTAssertEqual(gradient.evaluations, 4)

        let parameters = [2.0, -0.5]
        let xs = [0.0, 0.5, 1.0]
        let jacobian = xs.map { x -> [Double] in
            let e = exp(parameters[1] * x)
            return [e, parameters[0] * x * e]
        }
        let jacobianReport = try DerivativeCheck.jacobian(
            at: parameters, analytic: jacobian
        ) { p in xs.map { p[0] * exp(p[1] * $0) } }
        XCTAssertTrue(jacobianReport.passed)
        XCTAssertEqual(jacobianReport.evaluations, 4)
    }


    func testObserverCanCancelWithoutReportingNumericalFailure() throws {
        var snapshots: [LBFGSIteration] = []
        let result = try LBFGS.minimize(initial: [4], observer: { iteration in
            snapshots.append(iteration)
            return false
        }) { x in (x[0] * x[0], [2 * x[0]]) }
        XCTAssertEqual(result.termination, .cancelled)
        XCTAssertEqual(result.iterations, 1)
        XCTAssertEqual(snapshots.count, 1)
    }

    func testLBFGSBFindsSolutionOnActiveBounds() throws {
        let result = try LBFGSB.minimize(
            initial: [0, 0],
            bounds: [.init(upper: 1), .init(lower: -1)]
        ) { x in
            (pow(x[0] - 3, 2) + pow(x[1] + 2, 2),
             [2 * (x[0] - 3), 2 * (x[1] + 2)])
        }
        XCTAssertEqual(result.point[0], 1, accuracy: 1e-10)
        XCTAssertEqual(result.point[1], -1, accuracy: 1e-10)
        XCTAssertLessThan(result.gradientNorm, 1e-10)
    }

    func testRobustBoundedFitResistsOutlier() throws {
        let xs = [0.0, 1, 2, 3, 4], ys = [1.0, 3, 5, 7, 100]
        let result = try NonlinearLeastSquares.solve(
            initial: [0, 0], bounds: [.init(lower: 0, upper: 1.5), .free],
            loss: .huber(scale: 1)
        ) { p in
            .init(residuals: zip(xs, ys).map { p[0] + p[1] * $0 - $1 },
                  jacobian: xs.map { [1, $0] })
        }
        XCTAssertTrue((0...1.5).contains(result.point[0]))
        XCTAssertEqual(result.point[0], 1, accuracy: 0.51)
        XCTAssertEqual(result.point[1], 2, accuracy: 0.6)
    }

    func testZeroWeightExcludesOutlier() throws {
        let xs = [0.0, 1, 2, 3], ys = [1.0, 3, 5, 99]
        let result = try NonlinearLeastSquares.solve(
            initial: [0, 0], bounds: [.free, .free], weights: [1, 1, 1, 0]
        ) { p in
            .init(residuals: zip(xs, ys).map { p[0] + p[1] * $0 - $1 },
                  jacobian: xs.map { [1, $0] })
        }
        XCTAssertEqual(result.point[0], 1, accuracy: 1e-6)
        XCTAssertEqual(result.point[1], 2, accuracy: 1e-6)
    }
}
