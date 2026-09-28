import Foundation

public enum NonlinearTermination: Sendable, Hashable {
    case convergedGradient
    case convergedStep
    case convergedObjective
    case iterationLimit
    case lineSearchFailed
    case dampingLimit
}

public enum NonlinearOptimizationError: Error, Equatable {
    case invalidConfiguration(String)
    case invalidInitialPoint
    case invalidEvaluation(String)
}

public struct LBFGSOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var historySize: Int
    public var gradientTolerance: Double
    public var stepTolerance: Double
    public var objectiveTolerance: Double
    public var maxLineSearchIterations: Int
    public var armijo: Double
    public var backtracking: Double

    public init(maxIterations: Int = 1_000, historySize: Int = 10,
                gradientTolerance: Double = 1e-8, stepTolerance: Double = 1e-12,
                objectiveTolerance: Double = 1e-12,
                maxLineSearchIterations: Int = 30, armijo: Double = 1e-4,
                backtracking: Double = 0.5) {
        self.maxIterations = maxIterations
        self.historySize = historySize
        self.gradientTolerance = gradientTolerance
        self.stepTolerance = stepTolerance
        self.objectiveTolerance = objectiveTolerance
        self.maxLineSearchIterations = maxLineSearchIterations
        self.armijo = armijo
        self.backtracking = backtracking
    }
}

public struct LBFGSResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let gradient: [Double]
    public let iterations: Int
    public let evaluations: Int
    public let termination: NonlinearTermination
}

public enum LBFGS {
    public typealias Objective = ([Double]) throws -> (value: Double, gradient: [Double])

    public static func minimize(
        initial: [Double], options: LBFGSOptions = .init(), objective: Objective
    ) throws -> LBFGSResult {
        try validate(options)
        guard !initial.isEmpty, initial.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        var point = initial
        var current = try evaluate(objective, at: point)
        var evaluations = 1
        var steps: [[Double]] = []
        var gradientChanges: [[Double]] = []
        var inverseCurvatures: [Double] = []

        for iteration in 0..<options.maxIterations {
            if infinityNorm(current.gradient) <= options.gradientTolerance {
                return result(point, current, iteration, evaluations, .convergedGradient)
            }
            var direction = twoLoop(
                gradient: current.gradient, steps: steps,
                gradientChanges: gradientChanges, inverseCurvatures: inverseCurvatures
            )
            var slope = dot(current.gradient, direction)
            if !slope.isFinite || slope >= 0 {
                steps.removeAll(); gradientChanges.removeAll(); inverseCurvatures.removeAll()
                direction = current.gradient.map(-)
                slope = -dot(current.gradient, current.gradient)
            }

            var stepLength = 1.0
            var accepted: ([Double], (value: Double, gradient: [Double]), Double)?
            for _ in 0..<options.maxLineSearchIterations {
                let candidate = zip(point, direction).map { $0 + stepLength * $1 }
                if candidate.allSatisfy(\.isFinite) {
                    evaluations += 1
                    if let candidateEvaluation = try? evaluate(objective, at: candidate) {
                        if candidateEvaluation.value <= current.value
                            + options.armijo * stepLength * slope {
                            accepted = (candidate, candidateEvaluation, stepLength)
                            break
                        }
                    }
                }
                stepLength *= options.backtracking
            }
            guard let (nextPoint, next, acceptedLength) = accepted else {
                return result(point, current, iteration, evaluations, .lineSearchFailed)
            }

            let s = zip(nextPoint, point).map(-)
            let y = zip(next.gradient, current.gradient).map(-)
            let curvature = dot(s, y)
            if curvature > 1e-12 * norm(s) * norm(y) {
                if steps.count == options.historySize {
                    steps.removeFirst(); gradientChanges.removeFirst(); inverseCurvatures.removeFirst()
                }
                steps.append(s); gradientChanges.append(y); inverseCurvatures.append(1 / curvature)
            }
            let stepNorm = acceptedLength * norm(direction)
            let objectiveChange = abs(current.value - next.value)
            point = nextPoint
            current = next
            if stepNorm <= options.stepTolerance * (1 + norm(point)) {
                return result(point, current, iteration + 1, evaluations, .convergedStep)
            }
            if objectiveChange <= options.objectiveTolerance * (1 + abs(current.value)) {
                return result(point, current, iteration + 1, evaluations, .convergedObjective)
            }
        }
        return result(point, current, options.maxIterations, evaluations, .iterationLimit)
    }

    private static func validate(_ options: LBFGSOptions) throws {
        guard options.maxIterations > 0, options.historySize > 0,
              options.maxLineSearchIterations > 0,
              options.gradientTolerance.isFinite, options.gradientTolerance > 0,
              options.stepTolerance.isFinite, options.stepTolerance > 0,
              options.objectiveTolerance.isFinite, options.objectiveTolerance > 0,
              options.armijo > 0, options.armijo < 1,
              options.backtracking > 0, options.backtracking < 1 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid L-BFGS options")
        }
    }

    private static func evaluate(_ objective: Objective, at point: [Double]) throws
        -> (value: Double, gradient: [Double]) {
        let evaluation = try objective(point)
        guard evaluation.value.isFinite, evaluation.gradient.count == point.count,
              evaluation.gradient.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidEvaluation(
                "objective must return a finite value and a matching finite gradient")
        }
        return evaluation
    }

    private static func twoLoop(gradient: [Double], steps: [[Double]],
                                gradientChanges: [[Double]], inverseCurvatures: [Double]) -> [Double] {
        var q = gradient
        var alpha = [Double](repeating: 0, count: steps.count)
        for index in steps.indices.reversed() {
            alpha[index] = inverseCurvatures[index] * dot(steps[index], q)
            q = zip(q, gradientChanges[index]).map { $0 - alpha[index] * $1 }
        }
        if let s = steps.last, let y = gradientChanges.last {
            let scale = dot(s, y) / dot(y, y)
            q = q.map { scale * $0 }
        }
        for index in steps.indices {
            let beta = inverseCurvatures[index] * dot(gradientChanges[index], q)
            q = zip(q, steps[index]).map { $0 + (alpha[index] - beta) * $1 }
        }
        return q.map(-)
    }

    private static func result(_ point: [Double], _ evaluation: (value: Double, gradient: [Double]),
                               _ iterations: Int, _ evaluations: Int,
                               _ termination: NonlinearTermination) -> LBFGSResult {
        LBFGSResult(point: point, objective: evaluation.value, gradient: evaluation.gradient,
                    iterations: iterations, evaluations: evaluations, termination: termination)
    }
}

public struct NonlinearLeastSquaresOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var gradientTolerance: Double
    public var stepTolerance: Double
    public var costTolerance: Double
    public var initialDamping: Double
    public var dampingIncrease: Double
    public var dampingDecrease: Double
    public var maxDampingIterations: Int

    public init(maxIterations: Int = 200, gradientTolerance: Double = 1e-8,
                stepTolerance: Double = 1e-10, costTolerance: Double = 1e-12,
                initialDamping: Double = 1e-3, dampingIncrease: Double = 10,
                dampingDecrease: Double = 0.3, maxDampingIterations: Int = 20) {
        self.maxIterations = maxIterations
        self.gradientTolerance = gradientTolerance
        self.stepTolerance = stepTolerance
        self.costTolerance = costTolerance
        self.initialDamping = initialDamping
        self.dampingIncrease = dampingIncrease
        self.dampingDecrease = dampingDecrease
        self.maxDampingIterations = maxDampingIterations
    }
}

public struct NonlinearLeastSquaresEvaluation: Sendable, Hashable {
    public let residuals: [Double]
    /// Row-major Jacobian with one row per residual.
    public let jacobian: [[Double]]
    public init(residuals: [Double], jacobian: [[Double]]) {
        self.residuals = residuals
        self.jacobian = jacobian
    }
}

public struct NonlinearLeastSquaresResult: Sendable, Hashable {
    public let point: [Double]
    public let residuals: [Double]
    public let cost: Double
    public let gradientNorm: Double
    public let iterations: Int
    public let evaluations: Int
    public let termination: NonlinearTermination
}

public enum NonlinearLeastSquares {
    public typealias Model = ([Double]) throws -> NonlinearLeastSquaresEvaluation

    public static func solve(initial: [Double], options: NonlinearLeastSquaresOptions = .init(),
                             model: Model) throws -> NonlinearLeastSquaresResult {
        try validate(options)
        guard !initial.isEmpty, initial.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        var point = initial
        var evaluation = try evaluate(model, at: point)
        var evaluations = 1
        var cost = squaredCost(evaluation.residuals)
        var damping = options.initialDamping

        for iteration in 0..<options.maxIterations {
            let equations = normalEquations(evaluation, parameterCount: point.count)
            let gradientNorm = infinityNorm(equations.gradient)
            if gradientNorm <= options.gradientTolerance {
                return result(point, evaluation.residuals, cost, gradientNorm,
                              iteration, evaluations, .convergedGradient)
            }
            var accepted: ([Double], NonlinearLeastSquaresEvaluation, Double, Double)?
            for _ in 0..<options.maxDampingIterations {
                var damped = equations.normal
                for index in point.indices {
                    damped[index][index] += damping * max(abs(equations.normal[index][index]), 1)
                }
                if let step = choleskySolve(damped, equations.gradient.map(-)) {
                    let candidate = zip(point, step).map(+)
                    if candidate.allSatisfy(\.isFinite) {
                        evaluations += 1
                        if let next = try? evaluate(model, at: candidate) {
                            let nextCost = squaredCost(next.residuals)
                            if nextCost < cost {
                                accepted = (candidate, next, nextCost, norm(step))
                                damping = max(damping * options.dampingDecrease, .leastNonzeroMagnitude)
                                break
                            }
                        }
                    }
                }
                damping *= options.dampingIncrease
                if !damping.isFinite { break }
            }
            guard let (nextPoint, next, nextCost, stepNorm) = accepted else {
                return result(point, evaluation.residuals, cost, gradientNorm,
                              iteration, evaluations, .dampingLimit)
            }
            let costChange = cost - nextCost
            point = nextPoint; evaluation = next; cost = nextCost
            let nextGradient = normalEquations(evaluation, parameterCount: point.count).gradient
            if stepNorm <= options.stepTolerance * (1 + norm(point)) {
                return result(point, evaluation.residuals, cost, infinityNorm(nextGradient),
                              iteration + 1, evaluations, .convergedStep)
            }
            if costChange <= options.costTolerance * (1 + cost) {
                return result(point, evaluation.residuals, cost, infinityNorm(nextGradient),
                              iteration + 1, evaluations, .convergedObjective)
            }
        }
        let gradient = normalEquations(evaluation, parameterCount: point.count).gradient
        return result(point, evaluation.residuals, cost, infinityNorm(gradient),
                      options.maxIterations, evaluations, .iterationLimit)
    }

    private static func validate(_ options: NonlinearLeastSquaresOptions) throws {
        guard options.maxIterations > 0, options.maxDampingIterations > 0,
              options.gradientTolerance.isFinite, options.gradientTolerance > 0,
              options.stepTolerance.isFinite, options.stepTolerance > 0,
              options.costTolerance.isFinite, options.costTolerance > 0,
              options.initialDamping.isFinite, options.initialDamping > 0,
              options.dampingIncrease.isFinite, options.dampingIncrease > 1,
              options.dampingDecrease.isFinite, options.dampingDecrease > 0,
              options.dampingDecrease < 1 else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "invalid nonlinear least-squares options")
        }
    }

    private static func evaluate(_ model: Model, at point: [Double]) throws
        -> NonlinearLeastSquaresEvaluation {
        let value = try model(point)
        guard !value.residuals.isEmpty, value.jacobian.count == value.residuals.count,
              value.jacobian.allSatisfy({ $0.count == point.count }),
              value.residuals.allSatisfy(\.isFinite),
              value.jacobian.joined().allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidEvaluation(
                "residuals must be non-empty and the finite Jacobian must be m by n")
        }
        return value
    }

    private static func normalEquations(_ value: NonlinearLeastSquaresEvaluation,
                                        parameterCount: Int) -> (normal: [[Double]], gradient: [Double]) {
        var normal = [[Double]](repeating: [Double](repeating: 0, count: parameterCount),
                                count: parameterCount)
        var gradient = [Double](repeating: 0, count: parameterCount)
        for (row, residual) in zip(value.jacobian, value.residuals) {
            for j in 0..<parameterCount {
                gradient[j] += row[j] * residual
                for k in 0...j { normal[j][k] += row[j] * row[k] }
            }
        }
        for j in 0..<parameterCount { for k in 0..<j { normal[k][j] = normal[j][k] } }
        return (normal, gradient)
    }

    private static func result(_ point: [Double], _ residuals: [Double], _ cost: Double,
                               _ gradientNorm: Double, _ iterations: Int, _ evaluations: Int,
                               _ termination: NonlinearTermination) -> NonlinearLeastSquaresResult {
        .init(point: point, residuals: residuals, cost: cost, gradientNorm: gradientNorm,
              iterations: iterations, evaluations: evaluations, termination: termination)
    }
}

private func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
private func norm(_ values: [Double]) -> Double { sqrt(dot(values, values)) }
private func infinityNorm(_ values: [Double]) -> Double { values.map(abs).max() ?? 0 }
private func squaredCost(_ residuals: [Double]) -> Double { 0.5 * dot(residuals, residuals) }

private func choleskySolve(_ matrix: [[Double]], _ rightHandSide: [Double]) -> [Double]? {
    let n = matrix.count
    var lower = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    for i in 0..<n { for j in 0...i {
        var sum = matrix[i][j]
        for k in 0..<j { sum -= lower[i][k] * lower[j][k] }
        if i == j {
            guard sum > 0, sum.isFinite else { return nil }
            lower[i][j] = sqrt(sum)
        } else { lower[i][j] = sum / lower[j][j] }
    } }
    var y = [Double](repeating: 0, count: n)
    for i in 0..<n {
        var sum = rightHandSide[i]
        for k in 0..<i { sum -= lower[i][k] * y[k] }
        y[i] = sum / lower[i][i]
    }
    var x = [Double](repeating: 0, count: n)
    for i in (0..<n).reversed() {
        var sum = y[i]
        if i + 1 < n { for k in (i + 1)..<n { sum -= lower[k][i] * x[k] } }
        x[i] = sum / lower[i][i]
    }
    return x
}
