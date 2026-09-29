import Foundation

public enum NonlinearTermination: Sendable, Hashable {
    case convergedGradient
    case convergedStep
    case convergedObjective
    case iterationLimit
    case lineSearchFailed
    case dampingLimit
    case cancelled
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
    public var wolfe: Double
    public var backtracking: Double

    public init(maxIterations: Int = 1_000, historySize: Int = 10,
                gradientTolerance: Double = 1e-8, stepTolerance: Double = 1e-12,
                objectiveTolerance: Double = 1e-12,
                maxLineSearchIterations: Int = 30, armijo: Double = 1e-4,
                backtracking: Double = 0.5, wolfe: Double = 0.9) {
        self.maxIterations = maxIterations
        self.historySize = historySize
        self.gradientTolerance = gradientTolerance
        self.stepTolerance = stepTolerance
        self.objectiveTolerance = objectiveTolerance
        self.maxLineSearchIterations = maxLineSearchIterations
        self.armijo = armijo
        self.backtracking = backtracking
        self.wolfe = wolfe
    }
}

public struct LBFGSResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let gradient: [Double]
    public let iterations: Int
    public let evaluations: Int
    public let termination: NonlinearTermination
    public let gradientNorm: Double
    public let acceptedStep: Double?
    public let storedCurvaturePairs: Int
}

public struct LBFGSIteration: Sendable, Hashable {
    public let iteration: Int
    public let objective: Double
    public let gradientNorm: Double
    public let step: Double
    public let evaluations: Int
}

public enum LBFGS {
    public typealias Objective = ([Double]) throws -> (value: Double, gradient: [Double])
    public typealias Observer = (LBFGSIteration) -> Bool

    public static func minimize(
        initial: [Double], options: LBFGSOptions = .init(), observer: Observer? = nil,
        objective: Objective
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
        var lastStep: Double?

        for iteration in 0..<options.maxIterations {
            if infinityNorm(current.gradient) <= options.gradientTolerance {
                return result(point, current, iteration, evaluations, .convergedGradient,
                              lastStep, steps.count)
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
            var upperStep: Double?
            var accepted: ([Double], (value: Double, gradient: [Double]), Double)?
            for _ in 0..<options.maxLineSearchIterations {
                let candidate = zip(point, direction).map { $0 + stepLength * $1 }
                if candidate.allSatisfy(\.isFinite) {
                    evaluations += 1
                    if let candidateEvaluation = try? evaluate(objective, at: candidate) {
                        let candidateSlope = dot(candidateEvaluation.gradient, direction)
                        let decrease = candidateEvaluation.value <= current.value
                            + options.armijo * stepLength * slope
                        let curvature = abs(candidateSlope) <= options.wolfe * abs(slope)
                        if decrease && curvature {
                            accepted = (candidate, candidateEvaluation, stepLength)
                            break
                        } else if !decrease || candidateSlope >= 0 {
                            upperStep = stepLength
                            stepLength *= options.backtracking
                        } else if let upperStep {
                            stepLength = 0.5 * (stepLength + upperStep)
                        } else {
                            stepLength /= options.backtracking
                        }
                        continue
                    }
                }
                stepLength *= options.backtracking
            }
            guard let (nextPoint, next, acceptedLength) = accepted else {
                return result(point, current, iteration, evaluations, .lineSearchFailed,
                              lastStep, steps.count)
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
            lastStep = acceptedLength
            let objectiveChange = abs(current.value - next.value)
            point = nextPoint
            current = next
            if observer?(.init(iteration: iteration + 1, objective: current.value,
                               gradientNorm: infinityNorm(current.gradient),
                               step: acceptedLength, evaluations: evaluations)) == false {
                return result(point, current, iteration + 1, evaluations, .cancelled,
                              lastStep, steps.count)
            }
            if stepNorm <= options.stepTolerance * (1 + norm(point)) {
                return result(point, current, iteration + 1, evaluations, .convergedStep,
                              lastStep, steps.count)
            }
            if objectiveChange <= options.objectiveTolerance * (1 + abs(current.value)) {
                return result(point, current, iteration + 1, evaluations, .convergedObjective,
                              lastStep, steps.count)
            }
        }
        return result(point, current, options.maxIterations, evaluations, .iterationLimit,
                      lastStep, steps.count)
    }

    private static func validate(_ options: LBFGSOptions) throws {
        guard options.maxIterations > 0, options.historySize > 0,
              options.maxLineSearchIterations > 0,
              options.gradientTolerance.isFinite, options.gradientTolerance > 0,
              options.stepTolerance.isFinite, options.stepTolerance > 0,
              options.objectiveTolerance.isFinite, options.objectiveTolerance > 0,
              options.armijo > 0, options.armijo < 1,
              options.wolfe > options.armijo, options.wolfe < 1,
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
                               _ termination: NonlinearTermination, _ acceptedStep: Double?,
                               _ storedCurvaturePairs: Int) -> LBFGSResult {
        LBFGSResult(point: point, objective: evaluation.value, gradient: evaluation.gradient,
                    iterations: iterations, evaluations: evaluations, termination: termination,
                    gradientNorm: infinityNorm(evaluation.gradient), acceptedStep: acceptedStep,
                    storedCurvaturePairs: storedCurvaturePairs)
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
    public let finalDamping: Double
    public let acceptedSteps: Int
    public let rejectedSteps: Int
}

public struct NonlinearLeastSquaresIteration: Sendable, Hashable {
    public let iteration: Int
    public let cost: Double
    public let gradientNorm: Double
    public let stepNorm: Double
    public let damping: Double
    public let evaluations: Int
}

public enum NonlinearLeastSquares {
    public typealias Model = ([Double]) throws -> NonlinearLeastSquaresEvaluation
    public typealias Observer = (NonlinearLeastSquaresIteration) -> Bool

    public static func solve(initial: [Double], options: NonlinearLeastSquaresOptions = .init(),
                             observer: Observer? = nil,
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
        var acceptedSteps = 0
        var rejectedSteps = 0

        for iteration in 0..<options.maxIterations {
            let equations = normalEquations(evaluation, parameterCount: point.count)
            let gradientNorm = infinityNorm(equations.gradient)
            if gradientNorm <= options.gradientTolerance {
                return result(point, evaluation.residuals, cost, gradientNorm,
                              iteration, evaluations, .convergedGradient,
                              damping, acceptedSteps, rejectedSteps)
            }
            var accepted: ([Double], NonlinearLeastSquaresEvaluation, Double, Double)?
            for _ in 0..<options.maxDampingIterations {
                var augmented = evaluation.jacobian
                var rightHandSide = evaluation.residuals.map(-)
                for index in point.indices {
                    var row = [Double](repeating: 0, count: point.count)
                    row[index] = sqrt(damping * max(abs(equations.normal[index][index]), 1))
                    augmented.append(row)
                    rightHandSide.append(0)
                }
                if let step = leastSquaresQR(augmented, rightHandSide, tolerance: 1e-12) {
                    let candidate = zip(point, step).map(+)
                    if candidate.allSatisfy(\.isFinite) {
                        evaluations += 1
                        if let next = try? evaluate(model, at: candidate) {
                            let nextCost = squaredCost(next.residuals)
                            let predicted = predictedReduction(
                                gradient: equations.gradient, normal: equations.normal, step: step)
                            let gainRatio = predicted > 0 ? (cost - nextCost) / predicted : -.infinity
                            if gainRatio > 0, nextCost < cost {
                                accepted = (candidate, next, nextCost, norm(step))
                                if gainRatio > 0.75 {
                                    damping = max(damping * options.dampingDecrease, .leastNonzeroMagnitude)
                                } else if gainRatio < 0.25 {
                                    damping *= options.dampingIncrease
                                }
                                acceptedSteps += 1
                                break
                            }
                        }
                    }
                }
                damping *= options.dampingIncrease
                rejectedSteps += 1
                if !damping.isFinite { break }
            }
            guard let (nextPoint, next, nextCost, stepNorm) = accepted else {
                return result(point, evaluation.residuals, cost, gradientNorm,
                              iteration, evaluations, .dampingLimit,
                              damping, acceptedSteps, rejectedSteps)
            }
            let costChange = cost - nextCost
            point = nextPoint; evaluation = next; cost = nextCost
            let nextGradient = normalEquations(evaluation, parameterCount: point.count).gradient
            if observer?(.init(iteration: iteration + 1, cost: cost,
                               gradientNorm: infinityNorm(nextGradient), stepNorm: stepNorm,
                               damping: damping, evaluations: evaluations)) == false {
                return result(point, evaluation.residuals, cost, infinityNorm(nextGradient),
                              iteration + 1, evaluations, .cancelled,
                              damping, acceptedSteps, rejectedSteps)
            }
            if stepNorm <= options.stepTolerance * (1 + norm(point)) {
                return result(point, evaluation.residuals, cost, infinityNorm(nextGradient),
                              iteration + 1, evaluations, .convergedStep,
                              damping, acceptedSteps, rejectedSteps)
            }
            if costChange <= options.costTolerance * (1 + cost) {
                return result(point, evaluation.residuals, cost, infinityNorm(nextGradient),
                              iteration + 1, evaluations, .convergedObjective,
                              damping, acceptedSteps, rejectedSteps)
            }
        }
        let gradient = normalEquations(evaluation, parameterCount: point.count).gradient
        return result(point, evaluation.residuals, cost, infinityNorm(gradient),
                      options.maxIterations, evaluations, .iterationLimit,
                      damping, acceptedSteps, rejectedSteps)
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
                               _ termination: NonlinearTermination, _ finalDamping: Double,
                               _ acceptedSteps: Int, _ rejectedSteps: Int) -> NonlinearLeastSquaresResult {
        .init(point: point, residuals: residuals, cost: cost, gradientNorm: gradientNorm,
              iterations: iterations, evaluations: evaluations, termination: termination,
              finalDamping: finalDamping, acceptedSteps: acceptedSteps,
              rejectedSteps: rejectedSteps)
    }

    private static func predictedReduction(gradient: [Double], normal: [[Double]],
                                           step: [Double]) -> Double {
        let linear = dot(gradient, step)
        let quadratic = normal.indices.reduce(0.0) { partial, row in
            partial + 0.5 * step[row] * dot(normal[row], step)
        }
        return -linear - quadratic
    }
}

private func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
private func norm(_ values: [Double]) -> Double { sqrt(dot(values, values)) }
private func infinityNorm(_ values: [Double]) -> Double { values.map(abs).max() ?? 0 }
private func squaredCost(_ residuals: [Double]) -> Double { 0.5 * dot(residuals, residuals) }

private func leastSquaresQR(_ matrix: [[Double]], _ rightHandSide: [Double],
                            tolerance: Double) -> [Double]? {
    let rows = matrix.count
    guard let columns = matrix.first?.count, rows >= columns, columns > 0,
          rightHandSide.count == rows, matrix.allSatisfy({ $0.count == columns }) else { return nil }
    var r = matrix
    var transformed = rightHandSide
    let scale = max(matrix.joined().map(abs).max() ?? 0, 1)
    for column in 0..<columns {
        let columnNorm = sqrt((column..<rows).reduce(0) { $0 + r[$1][column] * r[$1][column] })
        guard columnNorm > tolerance * scale else { return nil }
        let alpha = r[column][column] >= 0 ? -columnNorm : columnNorm
        var reflector = (column..<rows).map { r[$0][column] }
        reflector[0] -= alpha
        let reflectorNorm = dot(reflector, reflector)
        guard reflectorNorm > 0 else { return nil }
        for j in column..<columns {
            let projection = 2 * reflector.indices.reduce(0) {
                $0 + reflector[$1] * r[column + $1][j]
            } / reflectorNorm
            for offset in reflector.indices { r[column + offset][j] -= projection * reflector[offset] }
        }
        let projection = 2 * reflector.indices.reduce(0) {
            $0 + reflector[$1] * transformed[column + $1]
        } / reflectorNorm
        for offset in reflector.indices { transformed[column + offset] -= projection * reflector[offset] }
    }
    var solution = [Double](repeating: 0, count: columns)
    for row in (0..<columns).reversed() {
        guard abs(r[row][row]) > tolerance * scale else { return nil }
        let tail = row + 1 < columns
            ? ((row + 1)..<columns).reduce(0) { $0 + r[row][$1] * solution[$1] } : 0
        solution[row] = (transformed[row] - tail) / r[row][row]
    }
    return solution.allSatisfy(\.isFinite) ? solution : nil
}
