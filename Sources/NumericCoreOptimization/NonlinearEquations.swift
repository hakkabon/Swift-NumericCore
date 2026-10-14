import Foundation

public struct NonlinearSystemEvaluation: Sendable, Hashable {
    public let residuals: [Double]
    public let jacobian: [[Double]]
    public init(residuals: [Double], jacobian: [[Double]]) {
        self.residuals = residuals; self.jacobian = jacobian
    }
}

public enum NonlinearSystemTermination: Sendable, Hashable {
    case convergedResidual
    case convergedStep
    case iterationLimit
    case lineSearchFailed
    case singularJacobian
    case krylovFailed
    case cancelled
}

public struct NonlinearSystemOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var residualTolerance: Double
    public var stepTolerance: Double
    public var maxLineSearchIterations: Int
    public var armijo: Double
    public var backtracking: Double
    public var jacobianReuseIterations: Int
    public var maxKrylovIterations: Int
    public var krylovTolerance: Double
    public var variableScale: [Double]
    public var residualScale: [Double]

    public init(maxIterations: Int = 100, residualTolerance: Double = 1e-9,
                stepTolerance: Double = 1e-11, maxLineSearchIterations: Int = 24,
                armijo: Double = 1e-4, backtracking: Double = 0.5,
                jacobianReuseIterations: Int = 0, maxKrylovIterations: Int = 200,
                krylovTolerance: Double = 1e-8, variableScale: [Double] = [],
                residualScale: [Double] = []) {
        self.maxIterations = maxIterations; self.residualTolerance = residualTolerance
        self.stepTolerance = stepTolerance; self.maxLineSearchIterations = maxLineSearchIterations
        self.armijo = armijo; self.backtracking = backtracking
        self.jacobianReuseIterations = jacobianReuseIterations
        self.maxKrylovIterations = maxKrylovIterations; self.krylovTolerance = krylovTolerance
        self.variableScale = variableScale; self.residualScale = residualScale
    }
}

public struct NonlinearSystemIteration: Sendable, Hashable {
    public let iteration: Int
    public let residualNorm: Double
    public let stepNorm: Double
    public let stepLength: Double
    public let evaluations: Int
    public let jacobianEvaluations: Int
}

public struct NonlinearSystemResult: Sendable, Hashable {
    public let point: [Double]
    public let residuals: [Double]
    public let residualNorm: Double
    public let iterations: Int
    public let evaluations: Int
    public let jacobianEvaluations: Int
    public let linearIterations: Int
    public let acceptedSteps: Int
    public let reusedJacobians: Int
    public let termination: NonlinearSystemTermination
}

/// A square vector equation graph, semantically distinct from least squares.
public struct NonlinearEquationModel: Sendable, Hashable {
    public let parameterCount: Int
    public let equations: [NonlinearExpression]

    public init(parameterCount: Int, equations: [NonlinearExpression]) throws {
        guard parameterCount > 0, equations.count == parameterCount else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "a nonlinear equation model must be square and non-empty")
        }
        for equation in equations { try equation.validate(parameterCount: parameterCount) }
        self.parameterCount = parameterCount; self.equations = equations
    }

    public func evaluate(parameters: [Double]) throws -> NonlinearSystemEvaluation {
        guard parameters.count == parameterCount else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        let values = try equations.map { try $0.evaluate(parameters: parameters) }
        return .init(residuals: values.map(\.value), jacobian: values.map(\.gradient))
    }
}

public enum NonlinearSystemSolver {
    public typealias System = ([Double]) throws -> NonlinearSystemEvaluation
    public typealias Residual = ([Double]) throws -> [Double]
    public typealias JacobianProduct = (_ point: [Double], _ direction: [Double]) throws -> [Double]
    public typealias Observer = (NonlinearSystemIteration) -> Bool

    public static func solve(model: NonlinearEquationModel, initial: [Double],
                             options: NonlinearSystemOptions = .init(),
                             observer: Observer? = nil) throws -> NonlinearSystemResult {
        try solve(initial: initial, options: options, observer: observer) {
            try model.evaluate(parameters: $0)
        }
    }

    /// Damped Newton with pivoted dense linear solves and optional Jacobian reuse.
    public static func solve(initial: [Double], options: NonlinearSystemOptions = .init(),
                             observer: Observer? = nil,
                             system: System) throws -> NonlinearSystemResult {
        let scales = try eqValidate(initial, options)
        var point = initial
        var current = try eqEvaluation(system, point, point.count)
        var evaluations = 1, jacobianEvaluations = 1, accepted = 0, reused = 0
        var cachedJacobian = current.jacobian, age = 0
        for iteration in 0..<options.maxIterations {
            let residualNorm = eqNorm(zip(current.residuals, scales.residual).map(*))
            if residualNorm <= options.residualTolerance {
                return eqResult(point, current.residuals, residualNorm, iteration, evaluations,
                                jacobianEvaluations, 0, accepted, reused, .convergedResidual)
            }
            let useCached = iteration > 0 && age <= options.jacobianReuseIterations
            if !useCached { cachedJacobian = current.jacobian; age = 0 }
            else { reused += 1 }
            let matrix = cachedJacobian.enumerated().map { row, values in
                values.indices.map { scales.residual[row] * values[$0] * scales.variable[$0] }
            }
            let rhs = zip(current.residuals, scales.residual).map { -$0 * $1 }
            guard let scaledStep = eqDenseSolve(matrix, rhs) else {
                return eqResult(point, current.residuals, residualNorm, iteration, evaluations,
                                jacobianEvaluations, 0, accepted, reused, .singularJacobian)
            }
            let step = zip(scaledStep, scales.variable).map(*)
            let stepNorm = eqNorm(step)
            if stepNorm <= options.stepTolerance * (1 + eqNorm(point)) {
                return eqResult(point, current.residuals, residualNorm, iteration, evaluations,
                                jacobianEvaluations, 0, accepted, reused, .convergedStep)
            }
            guard let next = try eqLineSearch(point, step, residualNorm, scales.residual,
                                               options, &evaluations, system) else {
                return eqResult(point, current.residuals, residualNorm, iteration, evaluations,
                                jacobianEvaluations, 0, accepted, reused, .lineSearchFailed)
            }
            point = next.point; current = next.evaluation; accepted += 1; age += 1
            if !useCached || age > options.jacobianReuseIterations { jacobianEvaluations += 1 }
            if observer?(.init(iteration: iteration + 1, residualNorm: next.norm,
                               stepNorm: next.alpha * stepNorm, stepLength: next.alpha,
                               evaluations: evaluations,
                               jacobianEvaluations: jacobianEvaluations)) == false {
                return eqResult(point, current.residuals, next.norm, iteration + 1, evaluations,
                                jacobianEvaluations, 0, accepted, reused, .cancelled)
            }
        }
        let norm = eqNorm(zip(current.residuals, scales.residual).map(*))
        return eqResult(point, current.residuals, norm, options.maxIterations, evaluations,
                        jacobianEvaluations, 0, accepted, reused, .iterationLimit)
    }

    /// Matrix-free damped inexact Newton using GMRES for each Newton equation.
    public static func solveMatrixFree(initial: [Double], options: NonlinearSystemOptions = .init(),
                                       observer: Observer? = nil, residual: Residual,
                                       jacobianProduct: JacobianProduct) throws
        -> NonlinearSystemResult {
        let scales = try eqValidate(initial, options)
        var point = initial, values = try eqResidual(residual, initial, initial.count)
        var evaluations = 1, products = 0, accepted = 0
        for iteration in 0..<options.maxIterations {
            let residualNorm = eqNorm(zip(values, scales.residual).map(*))
            if residualNorm <= options.residualTolerance {
                return eqResult(point, values, residualNorm, iteration, evaluations, iteration,
                                products, accepted, 0, .convergedResidual)
            }
            let rhs = zip(values, scales.residual).map { -$0 * $1 }
            let krylov = try eqGMRES(rhs: rhs, maximumIterations: options.maxKrylovIterations,
                                     tolerance: options.krylovTolerance) { direction in
                let physical = zip(direction, scales.variable).map(*)
                let product = try jacobianProduct(point, physical); products += 1
                guard product.count == point.count, product.allSatisfy(\.isFinite) else {
                    throw NonlinearOptimizationError.invalidEvaluation("invalid Jacobian product")
                }
                return zip(product, scales.residual).map(*)
            }
            guard krylov.converged else {
                return eqResult(point, values, residualNorm, iteration, evaluations, iteration + 1,
                                products, accepted, 0, .krylovFailed)
            }
            let step = zip(krylov.solution, scales.variable).map(*)
            let stepNorm = eqNorm(step)
            if stepNorm <= options.stepTolerance * (1 + eqNorm(point)) {
                return eqResult(point, values, residualNorm, iteration, evaluations, iteration + 1,
                                products, accepted, 0, .convergedStep)
            }
            guard let next = try eqResidualLineSearch(point, values, step, residualNorm,
                scales.residual, options, &evaluations, residual) else {
                return eqResult(point, values, residualNorm, iteration, evaluations, iteration + 1,
                                products, accepted, 0, .lineSearchFailed)
            }
            point = next.point; values = next.residuals; accepted += 1
            if observer?(.init(iteration: iteration + 1, residualNorm: next.norm,
                               stepNorm: next.alpha * stepNorm, stepLength: next.alpha,
                               evaluations: evaluations,
                               jacobianEvaluations: iteration + 1)) == false {
                return eqResult(point, values, next.norm, iteration + 1, evaluations, iteration + 1,
                                products, accepted, 0, .cancelled)
            }
        }
        let norm = eqNorm(zip(values, scales.residual).map(*))
        return eqResult(point, values, norm, options.maxIterations, evaluations,
                        options.maxIterations, products, accepted, 0, .iterationLimit)
    }
}

public struct ContinuationOptions: Sendable, Hashable {
    public var initialStep: Double
    public var minimumStep: Double
    public var maximumStep: Double
    public var growth: Double
    public var shrink: Double
    public var maxStages: Int
    public var corrector: NonlinearSystemOptions
    public init(initialStep: Double = 0.1, minimumStep: Double = 1e-5,
                maximumStep: Double = 0.25, growth: Double = 1.5,
                shrink: Double = 0.5, maxStages: Int = 200,
                corrector: NonlinearSystemOptions = .init()) {
        self.initialStep = initialStep; self.minimumStep = minimumStep
        self.maximumStep = maximumStep; self.growth = growth; self.shrink = shrink
        self.maxStages = maxStages; self.corrector = corrector
    }
}

public struct ContinuationStage: Sendable, Hashable {
    public let parameter: Double
    public let step: Double
    public let iterations: Int
    public let residualNorm: Double
}

public struct ContinuationResult: Sendable, Hashable {
    public let point: [Double]
    public let parameter: Double
    public let stages: [ContinuationStage]
    public let rejectedStages: Int
    public let evaluations: Int
    public let reachedTarget: Bool
}

public extension NonlinearSystemSolver {
    /// Natural parameter continuation with adaptive corrector steps.
    static func continueSolution(initial: [Double], from start: Double, to target: Double,
                                 options: ContinuationOptions = .init(),
                                 system: (_ parameter: Double, _ point: [Double]) throws
                                    -> NonlinearSystemEvaluation) throws -> ContinuationResult {
        guard start.isFinite, target.isFinite, options.initialStep > 0,
              options.minimumStep > 0, options.maximumStep >= options.initialStep,
              options.growth > 1, options.shrink > 0, options.shrink < 1,
              options.maxStages > 0 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid continuation options")
        }
        if start == target { return .init(point: initial, parameter: start, stages: [],
                                          rejectedStages: 0, evaluations: 0, reachedTarget: true) }
        let direction = target > start ? 1.0 : -1.0
        var point = initial, parameter = start, step = options.initialStep
        var stages: [ContinuationStage] = [], rejected = 0, evaluations = 0
        while stages.count + rejected < options.maxStages && parameter != target {
            let trial = direction > 0 ? min(parameter + step, target) : max(parameter - step, target)
            let result = try solve(initial: point, options: options.corrector) {
                try system(trial, $0)
            }
            evaluations += result.evaluations
            if result.termination == .convergedResidual || result.termination == .convergedStep {
                stages.append(.init(parameter: trial, step: abs(trial - parameter),
                                    iterations: result.iterations,
                                    residualNorm: result.residualNorm))
                point = result.point; parameter = trial
                step = min(options.maximumStep, step * options.growth)
            } else {
                rejected += 1; step *= options.shrink
                if step < options.minimumStep { break }
            }
        }
        return .init(point: point, parameter: parameter, stages: stages,
                     rejectedStages: rejected, evaluations: evaluations,
                     reachedTarget: parameter == target)
    }

    /// Pseudo-transient continuation solves `(J + I/dt) step = -F`, increasing
    /// the artificial timestep as the residual falls. This regularizes a
    /// singular or unhelpful initial Newton Jacobian.
    static func solvePseudoTransient(initial: [Double],
                                     options: PseudoTransientOptions = .init(),
                                     observer: Observer? = nil,
                                     system: System) throws -> NonlinearSystemResult {
        let scales = try eqValidate(initial, options.corrector)
        guard options.initialTimeStep.isFinite, options.initialTimeStep > 0,
              options.maximumTimeStep.isFinite,
              options.maximumTimeStep >= options.initialTimeStep,
              options.growth.isFinite, options.growth > 1,
              options.shrink.isFinite, options.shrink > 0, options.shrink < 1 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid pseudo-transient options")
        }
        var point = initial, current = try eqEvaluation(system, initial, initial.count)
        var evaluations = 1, accepted = 0, timeStep = options.initialTimeStep
        for iteration in 0..<options.corrector.maxIterations {
            let residualNorm = eqNorm(zip(current.residuals, scales.residual).map(*))
            if residualNorm <= options.corrector.residualTolerance {
                return eqResult(point, current.residuals, residualNorm, iteration, evaluations,
                                iteration + 1, 0, accepted, 0, .convergedResidual)
            }
            var matrix = current.jacobian.enumerated().map { row, values in
                values.indices.map { scales.residual[row] * values[$0] * scales.variable[$0] }
            }
            for index in matrix.indices { matrix[index][index] += 1 / timeStep }
            let rhs = zip(current.residuals, scales.residual).map { -$0 * $1 }
            guard let z = eqDenseSolve(matrix, rhs) else {
                return eqResult(point, current.residuals, residualNorm, iteration, evaluations,
                                iteration + 1, 0, accepted, 0, .singularJacobian)
            }
            let step = zip(z, scales.variable).map(*), candidate = zip(point, step).map(+)
            let next = try eqEvaluation(system, candidate, point.count); evaluations += 1
            let nextNorm = eqNorm(zip(next.residuals, scales.residual).map(*))
            if nextNorm < residualNorm {
                point = candidate; current = next; accepted += 1
                timeStep = min(options.maximumTimeStep, timeStep * options.growth)
                if observer?(.init(iteration: iteration + 1, residualNorm: nextNorm,
                                   stepNorm: eqNorm(step), stepLength: 1,
                                   evaluations: evaluations,
                                   jacobianEvaluations: iteration + 1)) == false {
                    return eqResult(point, current.residuals, nextNorm, iteration + 1,
                                    evaluations, iteration + 1, 0, accepted, 0, .cancelled)
                }
            } else {
                timeStep *= options.shrink
                if timeStep <= options.corrector.stepTolerance {
                    return eqResult(point, current.residuals, residualNorm, iteration + 1,
                                    evaluations, iteration + 1, 0, accepted, 0,
                                    .lineSearchFailed)
                }
            }
        }
        let residualNorm = eqNorm(zip(current.residuals, scales.residual).map(*))
        return eqResult(point, current.residuals, residualNorm,
                        options.corrector.maxIterations, evaluations,
                        options.corrector.maxIterations, 0, accepted, 0, .iterationLimit)
    }
}

public struct PseudoTransientOptions: Sendable, Hashable {
    public var initialTimeStep: Double
    public var maximumTimeStep: Double
    public var growth: Double
    public var shrink: Double
    public var corrector: NonlinearSystemOptions
    public init(initialTimeStep: Double = 0.1, maximumTimeStep: Double = 1e6,
                growth: Double = 2, shrink: Double = 0.5,
                corrector: NonlinearSystemOptions = .init()) {
        self.initialTimeStep = initialTimeStep; self.maximumTimeStep = maximumTimeStep
        self.growth = growth; self.shrink = shrink; self.corrector = corrector
    }
}

private func eqValidate(_ point: [Double], _ o: NonlinearSystemOptions) throws
    -> (variable: [Double], residual: [Double]) {
    guard !point.isEmpty, point.allSatisfy(\.isFinite), o.maxIterations > 0,
          o.residualTolerance.isFinite, o.residualTolerance > 0,
          o.stepTolerance.isFinite, o.stepTolerance > 0, o.maxLineSearchIterations > 0,
          o.armijo.isFinite, o.armijo > 0, o.armijo < 1,
          o.backtracking.isFinite, o.backtracking > 0, o.backtracking < 1,
          o.jacobianReuseIterations >= 0, o.maxKrylovIterations > 0,
          o.krylovTolerance.isFinite, o.krylovTolerance > 0 else {
        throw NonlinearOptimizationError.invalidConfiguration("invalid nonlinear-system options")
    }
    func scale(_ values: [Double]) throws -> [Double] {
        let result = values.isEmpty ? [Double](repeating: 1, count: point.count) : values
        guard result.count == point.count, result.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw NonlinearOptimizationError.invalidConfiguration("scales must be positive and dimension-matched")
        }
        return result
    }
    return try (scale(o.variableScale), scale(o.residualScale))
}

private func eqEvaluation(_ system: NonlinearSystemSolver.System, _ x: [Double], _ n: Int) throws
    -> NonlinearSystemEvaluation {
    let value = try system(x)
    guard value.residuals.count == n, value.jacobian.count == n,
          value.jacobian.allSatisfy({ $0.count == n }), value.residuals.allSatisfy(\.isFinite),
          value.jacobian.joined().allSatisfy(\.isFinite) else {
        throw NonlinearOptimizationError.invalidEvaluation("nonlinear system must return finite square residuals and Jacobian")
    }
    return value
}

private func eqResidual(_ f: NonlinearSystemSolver.Residual, _ x: [Double], _ n: Int) throws -> [Double] {
    let value = try f(x)
    guard value.count == n, value.allSatisfy(\.isFinite) else {
        throw NonlinearOptimizationError.invalidEvaluation("nonlinear residual must be finite and square")
    }
    return value
}

private func eqLineSearch(_ x: [Double], _ step: [Double],
                          _ norm: Double, _ scale: [Double], _ o: NonlinearSystemOptions,
                          _ evaluations: inout Int, _ f: NonlinearSystemSolver.System) throws
    -> (point: [Double], evaluation: NonlinearSystemEvaluation, norm: Double, alpha: Double)? {
    var alpha = 1.0
    for _ in 0..<o.maxLineSearchIterations {
        let candidate = zip(x, step).map { $0 + alpha * $1 }
        if candidate.allSatisfy(\.isFinite), let value = try? eqEvaluation(f, candidate, x.count) {
            evaluations += 1; let next = eqNorm(zip(value.residuals, scale).map(*))
            if next <= (1 - o.armijo * alpha) * norm { return (candidate, value, next, alpha) }
        }
        alpha *= o.backtracking
    }
    return nil
}

private func eqResidualLineSearch(_ x: [Double], _ current: [Double], _ step: [Double],
                                  _ norm: Double, _ scale: [Double], _ o: NonlinearSystemOptions,
                                  _ evaluations: inout Int, _ f: NonlinearSystemSolver.Residual) throws
    -> (point: [Double], residuals: [Double], norm: Double, alpha: Double)? {
    var alpha = 1.0
    for _ in 0..<o.maxLineSearchIterations {
        let candidate = zip(x, step).map { $0 + alpha * $1 }
        if candidate.allSatisfy(\.isFinite), let value = try? eqResidual(f, candidate, x.count) {
            evaluations += 1; let next = eqNorm(zip(value, scale).map(*))
            if next <= (1 - o.armijo * alpha) * norm { return (candidate, value, next, alpha) }
        }
        alpha *= o.backtracking
    }
    return nil
}

private func eqDenseSolve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
    var a = matrix, b = rhs; let n = rhs.count
    for column in 0..<n {
        let pivot = (column..<n).max { abs(a[$0][column]) < abs(a[$1][column]) }!
        if abs(a[pivot][column]) <= 1e-14 { return nil }
        a.swapAt(column, pivot); b.swapAt(column, pivot)
        for row in (column + 1)..<n {
            let factor = a[row][column] / a[column][column]
            for entry in column..<n { a[row][entry] -= factor * a[column][entry] }
            b[row] -= factor * b[column]
        }
    }
    var x = [Double](repeating: 0, count: n)
    for row in stride(from: n - 1, through: 0, by: -1) {
        x[row] = (b[row] - ((row + 1)..<n).reduce(0) { $0 + a[row][$1] * x[$1] }) / a[row][row]
    }
    return x.allSatisfy(\.isFinite) ? x : nil
}

private func eqGMRES(rhs: [Double], maximumIterations: Int, tolerance: Double,
                     product: ([Double]) throws -> [Double]) throws
    -> (solution: [Double], iterations: Int, converged: Bool) {
    let beta = eqNorm(rhs), n = rhs.count, limit = min(maximumIterations, n)
    if beta == 0 { return ([Double](repeating: 0, count: n), 0, true) }
    var basis = [rhs.map { $0 / beta }], h = [[Double]](
        repeating: [Double](repeating: 0, count: limit), count: limit + 1)
    var cosine = [Double](repeating: 0, count: limit), sine = cosine
    var g = [Double](repeating: 0, count: limit + 1); g[0] = beta
    for column in 0..<limit {
        var w = try product(basis[column])
        for row in 0...column { h[row][column] = eqDot(w, basis[row]); eqAxpy(&w, -h[row][column], basis[row]) }
        h[column + 1][column] = eqNorm(w)
        if h[column + 1][column] > 0 { basis.append(w.map { $0 / h[column + 1][column] }) }
        for row in 0..<column {
            let first = cosine[row] * h[row][column] + sine[row] * h[row + 1][column]
            h[row + 1][column] = -sine[row] * h[row][column] + cosine[row] * h[row + 1][column]
            h[row][column] = first
        }
        let radius = hypot(h[column][column], h[column + 1][column])
        if radius == 0 { return ([Double](repeating: 0, count: n), column + 1, false) }
        cosine[column] = h[column][column] / radius; sine[column] = h[column + 1][column] / radius
        h[column][column] = radius; h[column + 1][column] = 0
        g[column + 1] = -sine[column] * g[column]; g[column] *= cosine[column]
        if abs(g[column + 1]) <= tolerance * max(beta, 1) || column + 1 == limit {
            var y = [Double](repeating: 0, count: column + 1)
            for row in stride(from: column, through: 0, by: -1) {
                let upper = row < column
                    ? ((row + 1)...column).reduce(0) { $0 + h[row][$1] * y[$1] } : 0
                y[row] = (g[row] - upper) / h[row][row]
            }
            var solution = [Double](repeating: 0, count: n)
            for k in 0...column { eqAxpy(&solution, y[k], basis[k]) }
            return (solution, column + 1, abs(g[column + 1]) <= tolerance * max(beta, 1))
        }
    }
    return ([Double](repeating: 0, count: n), limit, false)
}

private func eqResult(_ point: [Double], _ residuals: [Double], _ norm: Double,
                      _ iterations: Int, _ evaluations: Int, _ jacobians: Int,
                      _ linearIterations: Int, _ accepted: Int, _ reused: Int,
                      _ termination: NonlinearSystemTermination) -> NonlinearSystemResult {
    .init(point: point, residuals: residuals, residualNorm: norm, iterations: iterations,
          evaluations: evaluations, jacobianEvaluations: jacobians,
          linearIterations: linearIterations, acceptedSteps: accepted,
          reusedJacobians: reused, termination: termination)
}
private func eqDot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
private func eqNorm(_ a: [Double]) -> Double { sqrt(eqDot(a, a)) }
private func eqAxpy(_ x: inout [Double], _ alpha: Double, _ y: [Double]) {
    for index in x.indices { x[index] += alpha * y[index] }
}
