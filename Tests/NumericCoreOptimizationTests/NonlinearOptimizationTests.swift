import XCTest
@testable import NumericCoreOptimization

final class NonlinearOptimizationTests: XCTestCase {
    func testSQPSolvesEqualityConstrainedQuadratic() throws {
        let objective = NonlinearExpression(nodes: [
            .parameter(0), .pow(0, 2), .parameter(1), .pow(2, 2), .add(1, 3)
        ], output: 4)
        let equality = NonlinearExpression(
            nodes: [.parameter(0), .parameter(1), .add(0, 1)], output: 2)
        let model = try NonlinearModel.objective(
            parameterCount: 2, bounds: [.free, .free], expression: objective)
        let problem = try ConstrainedNonlinearProblem(
            model: model, constraints: [.init(expression: equality, bound: .fixed(1))])
        let result = try SequentialQuadraticProgramming.minimize(
            problem: problem, initial: [0, 0])
        XCTAssertEqual(result.termination, .converged)
        XCTAssertEqual(result.point[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(result.point[1], 0.5, accuracy: 1e-5)
        XCTAssertLessThan(result.maximumViolation, 1e-7)
        XCTAssertLessThan(result.stationarityNorm, 1e-5)
    }

    func testSQPSolvesActiveNonlinearInequalityAcrossBackends() throws {
        let objective = NonlinearExpression(nodes: [
            .parameter(0), .constant(2), .subtract(0, 1), .pow(2, 2)
        ], output: 3)
        let constraint = NonlinearExpression(nodes: [.parameter(0), .pow(0, 2)], output: 1)
        let model = try NonlinearModel.objective(
            parameterCount: 1, bounds: [.free], expression: objective)
        let problem = try ConstrainedNonlinearProblem(
            model: model,
            constraints: [.init(expression: constraint, bound: .init(upper: 1))])
        let swift = try NonlinearModelSolver.minimizeSQP(
            problem: problem, initial: [0.5], backend: .swift)
        let rust = try NonlinearModelSolver.minimizeSQP(
            problem: problem, initial: [0.5], backend: .rust)
        for result in [swift, rust] {
            XCTAssertEqual(result.termination, .converged)
            XCTAssertEqual(result.point[0], 1, accuracy: 1e-5)
            XCTAssertLessThan(result.maximumViolation, 1e-7)
            XCTAssertGreaterThan(result.multipliers[0].upper, 0)
        }
        XCTAssertEqual(rust.point[0], swift.point[0], accuracy: 1e-7)
    }

    func testSparseAndMatrixFreeDerivativesAgree() throws {
        func shifted(_ parameter: Int, _ constant: Double) -> NonlinearExpression {
            .init(nodes: [.parameter(parameter), .constant(constant), .subtract(0, 1)], output: 2)
        }
        let model = try NonlinearModel.leastSquares(
            parameterCount: 4, bounds: [.free, .free, .free, .free],
            residuals: [shifted(0, 1), shifted(3, 2)])
        let point = [3.0, 7, 8, 5], direction = [2.0, 4, 6, 8]
        let sparse = try model.evaluateSparseResiduals(parameters: point)
        XCTAssertEqual(sparse.residuals, [2, 3])
        XCTAssertEqual(sparse.jacobian.rowPointers, [0, 1, 2])
        XCTAssertEqual(sparse.jacobian.columnIndices, [0, 3])
        XCTAssertEqual(sparse.jacobian.values, [1, 1])
        XCTAssertEqual(try sparse.jacobian.multiplying(direction),
                       try model.jacobianVectorProduct(parameters: point, direction: direction))
        XCTAssertEqual(try sparse.jacobian.transposeMultiplying([5, 7]),
                       try model.jacobianTransposeVectorProduct(parameters: point, weights: [5, 7]))
    }

    func testSparseDerivativesCrossRustFFI() throws {
        func shifted(_ parameter: Int, _ constant: Double) -> NonlinearExpression {
            .init(nodes: [.parameter(parameter), .constant(constant), .subtract(0, 1)], output: 2)
        }
        let model = try NonlinearModel.leastSquares(
            parameterCount: 4, bounds: [.free, .free, .free, .free],
            residuals: [shifted(0, 1), shifted(3, 2)])
        let point = [3.0, 7, 8, 5], direction = [2.0, 4, 6, 8]
        let local = try NonlinearModelSolver.sparseResiduals(
            model: model, parameters: point, backend: .swift)
        let remote = try NonlinearModelSolver.sparseResiduals(
            model: model, parameters: point, backend: .rust)
        XCTAssertEqual(remote, local)
        XCTAssertEqual(
            try NonlinearModelSolver.jacobianVectorProduct(
                model: model, parameters: point, direction: direction, backend: .rust),
            try local.jacobian.multiplying(direction))
        XCTAssertEqual(
            try NonlinearModelSolver.jacobianTransposeVectorProduct(
                model: model, parameters: point, weights: [5, 7], backend: .rust),
            try local.jacobian.transposeMultiplying([5, 7]))
    }

    func testSparseObjectiveCrossesRustFFI() throws {
        let expression = NonlinearExpression(
            nodes: [.parameter(2), .constant(4), .multiply(0, 1)], output: 2)
        let model = try NonlinearModel.objective(
            parameterCount: 4, bounds: [.free, .free, .free, .free], expression: expression)
        let point = [1.0, 2, 3, 4]
        let local = try NonlinearModelSolver.sparseObjective(
            model: model, parameters: point, backend: .swift)
        let remote = try NonlinearModelSolver.sparseObjective(
            model: model, parameters: point, backend: .rust)
        XCTAssertEqual(remote, local)
        XCTAssertEqual(remote.value, 12)
        XCTAssertEqual(remote.derivative.indices, [2])
        XCTAssertEqual(remote.derivative.values, [4])
    }
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

    func testSharedObjectiveGraphRunsThroughBoundedSolver() throws {
        let expression = NonlinearExpression(nodes: [
            .parameter(0), .constant(3), .subtract(0, 1), .pow(2, 2)
        ], output: 3)
        let model = try NonlinearModel.objective(
            parameterCount: 1, bounds: [.init(upper: 1)], expression: expression)
        let result = try LBFGSB.minimize(model: model, initial: [0])
        XCTAssertEqual(result.point[0], 1, accuracy: 1e-10)
        XCTAssertLessThan(result.gradientNorm, 1e-10)
    }

    func testUnifiedNonlinearSolverUsesSharedSwiftContract() throws {
        let expression = NonlinearExpression(nodes: [
            .parameter(0), .constant(3), .subtract(0, 1), .pow(2, 2)
        ], output: 3)
        let model = try NonlinearModel.objective(
            parameterCount: 1, bounds: [.init(upper: 1)], expression: expression)
        let result = try NonlinearModelSolver.minimize(
            model: model, initial: [0], backend: .swift)
        XCTAssertEqual(result.point[0], 1, accuracy: 1e-10)
    }

    func testUnifiedNonlinearSolverCrossesRustFFI() throws {
        let expression = NonlinearExpression(nodes: [
            .parameter(0), .constant(3), .subtract(0, 1), .pow(2, 2)
        ], output: 3)
        let model = try NonlinearModel.objective(
            parameterCount: 1, bounds: [.init(upper: 1)], expression: expression)
        let result = try NonlinearModelSolver.minimize(
            model: model, initial: [0], backend: .rust)
        XCTAssertEqual(result.point[0], 1, accuracy: 1e-10)
        XCTAssertEqual(result.termination, .convergedGradient)
    }

    func testUnifiedRobustLeastSquaresCrossesRustFFI() throws {
        func shifted(_ constant: Double) -> NonlinearExpression {
            .init(nodes: [.parameter(0), .constant(constant), .subtract(0, 1)], output: 2)
        }
        let model = try NonlinearModel.leastSquares(
            parameterCount: 1, bounds: [.free], residuals: [shifted(1), shifted(2)])
        let result = try NonlinearModelSolver.leastSquares(
            model: model, initial: [0], loss: .huber(scale: 1), backend: .rust)
        XCTAssertEqual(result.point[0], 1.5, accuracy: 1e-8)
    }

    func testUnifiedConstrainedSolverCrossesRustFFI() throws {
        let objective = NonlinearExpression(nodes: [
            .parameter(0), .pow(0, 2), .parameter(1), .pow(2, 2), .add(1, 3)
        ], output: 4)
        let equality = NonlinearExpression(nodes: [
            .parameter(0), .parameter(1), .add(0, 1)
        ], output: 2)
        let model = try NonlinearModel.objective(
            parameterCount: 2, bounds: [.free, .free], expression: objective)
        let problem = try ConstrainedNonlinearProblem(
            model: model, constraints: [.init(expression: equality, bound: .fixed(1))])
        let result = try NonlinearModelSolver.minimize(
            problem: problem, initial: [0, 0], backend: .rust)
        XCTAssertEqual(result.termination, .converged)
        XCTAssertEqual(result.point[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(result.point[1], 0.5, accuracy: 1e-5)
    }

    func testSharedResidualGraphRunsThroughLeastSquaresSolver() throws {
        func shifted(_ constant: Double) -> NonlinearExpression {
            .init(nodes: [.parameter(0), .constant(constant), .subtract(0, 1)], output: 2)
        }
        let model = try NonlinearModel.leastSquares(
            parameterCount: 1, bounds: [.free], residuals: [shifted(1), shifted(2)])
        let evaluation = try model.evaluateResiduals(parameters: [2])
        XCTAssertEqual(evaluation.residuals, [1, 0])
        XCTAssertEqual(evaluation.jacobian, [[1], [1]])
        let result = try NonlinearLeastSquares.solve(model: model, initial: [0])
        XCTAssertEqual(result.point[0], 1.5, accuracy: 1e-8)
    }

    func testSharedGraphRejectsForwardReference() throws {
        let expression = NonlinearExpression(nodes: [.add(0, 0)], output: 0)
        XCTAssertThrowsError(try expression.validate(parameterCount: 1))
    }

    func testConstrainedSolverHandlesEquality() throws {
        let objective = NonlinearExpression(nodes: [
            .parameter(0), .pow(0, 2), .parameter(1), .pow(2, 2), .add(1, 3)
        ], output: 4)
        let equality = NonlinearExpression(nodes: [
            .parameter(0), .parameter(1), .add(0, 1)
        ], output: 2)
        let model = try NonlinearModel.objective(
            parameterCount: 2, bounds: [.free, .free], expression: objective)
        let problem = try ConstrainedNonlinearProblem(
            model: model, constraints: [.init(expression: equality, bound: .fixed(1))])
        let result = try ConstrainedNonlinearSolver.minimize(problem: problem, initial: [0, 0])
        XCTAssertEqual(result.termination, .converged)
        XCTAssertEqual(result.point[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(result.point[1], 0.5, accuracy: 1e-5)
        XCTAssertLessThan(result.maximumViolation, 1e-7)
    }

    func testConstrainedSolverHandlesActiveNonlinearInequality() throws {
        let objective = NonlinearExpression(nodes: [
            .parameter(0), .constant(2), .subtract(0, 1), .pow(2, 2)
        ], output: 3)
        let constraint = NonlinearExpression(nodes: [.parameter(0), .pow(0, 2)], output: 1)
        let model = try NonlinearModel.objective(
            parameterCount: 1, bounds: [.init(lower: 0)], expression: objective)
        let problem = try ConstrainedNonlinearProblem(
            model: model, constraints: [.init(expression: constraint, bound: .init(upper: 1))])
        let result = try ConstrainedNonlinearSolver.minimize(problem: problem, initial: [0.5])
        XCTAssertEqual(result.point[0], 1, accuracy: 1e-5)
        XCTAssertLessThan(result.maximumViolation, 1e-7)
        XCTAssertGreaterThan(result.multipliers[0].upper, 0)
    }

    func testConvexQPHandlesActiveVariableBound() throws {
        let problem = QuadraticProblem(
            quadratic: [[2]], linear: [-4],
            constraints: try .empty(columns: 1), rowBounds: [],
            variableBounds: [.init(lower: 0, upper: 1)])
        let result = try ConvexQuadraticSolver.solve(problem)
        XCTAssertEqual(result.termination, .converged)
        XCTAssertEqual(result.point[0], 1, accuracy: 1e-5)
        XCTAssertLessThan(result.maximumVariableViolation, 1e-5)
    }

    func testConvexQPHandlesEqualityConstraint() throws {
        let matrix = try QuadraticConstraintMatrix(
            rows: 1, columns: 2, rowPointers: [0, 2],
            columnIndices: [0, 1], values: [1, 1])
        let problem = QuadraticProblem(
            quadratic: [[2, 0], [0, 2]], linear: [0, 0], constraints: matrix,
            rowBounds: [.fixed(1)], variableBounds: [.free, .free])
        let result = try ConvexQuadraticSolver.solve(problem)
        XCTAssertEqual(result.point[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(result.point[1], 0.5, accuracy: 1e-5)
        XCTAssertLessThan(result.maximumRowViolation, 1e-5)
        XCTAssertLessThan(result.stationarityNorm, 1e-5)

        let restarted = try ConvexQuadraticSolver.solve(problem, warmStart: result.warmStart)
        XCTAssertEqual(restarted.termination, .converged)
        XCTAssertEqual(restarted.point[0], 0.5, accuracy: 1e-5)
        XCTAssertLessThanOrEqual(restarted.iterations, result.iterations)
    }

    func testConvexQPRejectsIndefiniteHessian() throws {
        let problem = QuadraticProblem(
            quadratic: [[-1]], linear: [0], constraints: try .empty(columns: 1),
            rowBounds: [], variableBounds: [.free])
        XCTAssertThrowsError(try ConvexQuadraticSolver.solve(problem))
    }
}
