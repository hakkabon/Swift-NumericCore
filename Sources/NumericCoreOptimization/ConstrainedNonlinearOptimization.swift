import Foundation

public struct NonlinearConstraint: Sendable, Hashable {
    public let expression: NonlinearExpression
    public let bound: ParameterBound
    public init(expression: NonlinearExpression, bound: ParameterBound) {
        self.expression = expression; self.bound = bound
    }
}

public struct ConstrainedNonlinearProblem: Sendable, Hashable {
    public let model: NonlinearModel
    public let constraints: [NonlinearConstraint]
    public init(model: NonlinearModel, constraints: [NonlinearConstraint]) throws {
        self.model = model; self.constraints = constraints
        try validate()
    }
    public func validate() throws {
        try model.validate()
        guard model.objective != nil, !constraints.isEmpty else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "constrained problem requires an objective and constraints")
        }
        for constraint in constraints {
            try constraint.expression.validate(parameterCount: model.parameterCount)
            guard constraint.bound.lower != nil || constraint.bound.upper != nil,
                  constrainedValidBound(constraint.bound) else {
                throw NonlinearOptimizationError.invalidConfiguration(
                    "nonlinear constraint must have a valid finite bound")
            }
        }
    }
    public func evaluateConstraints(at point: [Double]) throws -> [DifferentiableValue] {
        try validate()
        guard point.count == model.parameterCount else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        return try constraints.map { try $0.expression.evaluate(parameters: point) }
    }
}

public struct ConstrainedOptions: Sendable, Hashable {
    public var maxOuterIterations: Int
    public var feasibilityTolerance: Double
    public var stationarityTolerance: Double
    public var initialPenalty: Double
    public var penaltyIncrease: Double
    public var maximumPenalty: Double
    public var innerOptions: LBFGSOptions
    public init(maxOuterIterations: Int = 30, feasibilityTolerance: Double = 1e-7,
                stationarityTolerance: Double = 1e-6, initialPenalty: Double = 10,
                penaltyIncrease: Double = 10, maximumPenalty: Double = 1e10,
                innerOptions: LBFGSOptions = .init(maxIterations: 300)) {
        self.maxOuterIterations = maxOuterIterations
        self.feasibilityTolerance = feasibilityTolerance
        self.stationarityTolerance = stationarityTolerance
        self.initialPenalty = initialPenalty
        self.penaltyIncrease = penaltyIncrease
        self.maximumPenalty = maximumPenalty
        self.innerOptions = innerOptions
    }
}

public enum ConstrainedTermination: Sendable, Hashable {
    case converged, iterationLimit, penaltyLimit, cancelled
}

public struct ConstraintMultiplier: Sendable, Hashable {
    public var lower: Double
    public var upper: Double
    public var equality: Double
    public init(lower: Double = 0, upper: Double = 0, equality: Double = 0) {
        self.lower = lower; self.upper = upper; self.equality = equality
    }
}

public struct ConstrainedResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let constraintValues: [Double]
    public let multipliers: [ConstraintMultiplier]
    public let maximumViolation: Double
    public let stationarityNorm: Double
    public let outerIterations: Int
    public let innerIterations: Int
    public let evaluations: Int
    public let finalPenalty: Double
    public let termination: ConstrainedTermination
}

public struct ConstrainedIteration: Sendable, Hashable {
    public let iteration: Int
    public let objective: Double
    public let maximumViolation: Double
    public let stationarityNorm: Double
    public let penalty: Double
}

public enum ConstrainedNonlinearSolver {
    public typealias Observer = (ConstrainedIteration) -> Bool

    public static func minimize(problem: ConstrainedNonlinearProblem, initial: [Double],
                                options: ConstrainedOptions = .init(), observer: Observer? = nil)
        throws -> ConstrainedResult {
        try problem.validate(); try validate(options)
        guard initial.count == problem.model.parameterCount, initial.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        var point = initial
        var multipliers = [ConstraintMultiplier](repeating: .init(), count: problem.constraints.count)
        var penalty = options.initialPenalty, previousViolation = Double.infinity
        var innerIterations = 0, evaluations = 0
        for outer in 0..<options.maxOuterIterations {
            let inner = try LBFGSB.minimize(initial: point, bounds: problem.model.bounds,
                                            options: options.innerOptions) { x in
                evaluations += 1
                return try augmentedValue(problem, x, multipliers, penalty)
            }
            innerIterations += inner.iterations; point = inner.point
            let objective = try problem.model.evaluateObjective(parameters: point)
            let values = try problem.evaluateConstraints(at: point)
            updateMultipliers(problem, values, &multipliers, penalty)
            let violation = maximumViolation(problem, values)
            let stationarity = stationarityNorm(
                problem, point, objective.gradient, values, multipliers)
            let snapshot = ConstrainedIteration(
                iteration: outer + 1, objective: objective.value,
                maximumViolation: violation, stationarityNorm: stationarity, penalty: penalty)
            if observer?(snapshot) == false {
                return result(point, objective.value, values, multipliers, violation, stationarity,
                              outer + 1, innerIterations, evaluations, penalty, .cancelled)
            }
            if violation <= options.feasibilityTolerance,
               stationarity <= options.stationarityTolerance {
                return result(point, objective.value, values, multipliers, violation, stationarity,
                              outer + 1, innerIterations, evaluations, penalty, .converged)
            }
            if violation > 0.25 * previousViolation {
                penalty *= options.penaltyIncrease
                if !penalty.isFinite || penalty > options.maximumPenalty {
                    return result(point, objective.value, values, multipliers, violation,
                                  stationarity, outer + 1, innerIterations, evaluations,
                                  penalty, .penaltyLimit)
                }
            }
            previousViolation = violation
        }
        let objective = try problem.model.evaluateObjective(parameters: point)
        let values = try problem.evaluateConstraints(at: point)
        let violation = maximumViolation(problem, values)
        let stationarity = stationarityNorm(problem, point, objective.gradient, values, multipliers)
        return result(point, objective.value, values, multipliers, violation, stationarity,
                      options.maxOuterIterations, innerIterations, evaluations, penalty, .iterationLimit)
    }

    private static func validate(_ options: ConstrainedOptions) throws {
        guard options.maxOuterIterations > 0, options.feasibilityTolerance.isFinite,
              options.feasibilityTolerance > 0, options.stationarityTolerance.isFinite,
              options.stationarityTolerance > 0, options.initialPenalty.isFinite,
              options.initialPenalty > 0, options.penaltyIncrease.isFinite,
              options.penaltyIncrease > 1, options.maximumPenalty.isFinite,
              options.maximumPenalty >= options.initialPenalty else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "invalid constrained nonlinear options")
        }
    }

    private static func result(_ point: [Double], _ objective: Double,
                               _ values: [DifferentiableValue],
                               _ multipliers: [ConstraintMultiplier], _ violation: Double,
                               _ stationarity: Double, _ outer: Int, _ inner: Int,
                               _ evaluations: Int, _ penalty: Double,
                               _ termination: ConstrainedTermination) -> ConstrainedResult {
        .init(point: point, objective: objective, constraintValues: values.map(\.value),
              multipliers: multipliers, maximumViolation: violation,
              stationarityNorm: stationarity, outerIterations: outer,
              innerIterations: inner, evaluations: evaluations,
              finalPenalty: penalty, termination: termination)
    }
}

private func augmentedValue(_ problem: ConstrainedNonlinearProblem, _ point: [Double],
                            _ multipliers: [ConstraintMultiplier], _ penalty: Double) throws
    -> (Double, [Double]) {
    let objective = try problem.model.evaluateObjective(parameters: point)
    let values = try problem.evaluateConstraints(at: point)
    var total = objective.value, gradient = objective.gradient
    for ((constraint, value), multiplier) in zip(zip(problem.constraints, values), multipliers) {
        if let lower = constraint.bound.lower, let upper = constraint.bound.upper, lower == upper {
            let residual = value.value - lower
            total += multiplier.equality * residual + 0.5 * penalty * residual * residual
            constrainedAdd(&gradient, value.gradient, multiplier.equality + penalty * residual)
            continue
        }
        if let lower = constraint.bound.lower {
            let residual = lower - value.value
            let shifted = max(0, multiplier.lower + penalty * residual)
            total += (shifted * shifted - multiplier.lower * multiplier.lower) / (2 * penalty)
            constrainedAdd(&gradient, value.gradient, -shifted)
        }
        if let upper = constraint.bound.upper {
            let residual = value.value - upper
            let shifted = max(0, multiplier.upper + penalty * residual)
            total += (shifted * shifted - multiplier.upper * multiplier.upper) / (2 * penalty)
            constrainedAdd(&gradient, value.gradient, shifted)
        }
    }
    return (total, gradient)
}

private func updateMultipliers(_ problem: ConstrainedNonlinearProblem,
                               _ values: [DifferentiableValue],
                               _ multipliers: inout [ConstraintMultiplier], _ penalty: Double) {
    for index in problem.constraints.indices {
        let constraint = problem.constraints[index], value = values[index].value
        if let lower = constraint.bound.lower, let upper = constraint.bound.upper, lower == upper {
            multipliers[index].equality += penalty * (value - lower); continue
        }
        if let lower = constraint.bound.lower {
            multipliers[index].lower = max(0, multipliers[index].lower + penalty * (lower - value))
        }
        if let upper = constraint.bound.upper {
            multipliers[index].upper = max(0, multipliers[index].upper + penalty * (value - upper))
        }
    }
}

private func maximumViolation(_ problem: ConstrainedNonlinearProblem,
                              _ values: [DifferentiableValue]) -> Double {
    zip(problem.constraints, values).reduce(0) { maximum, pair in
        max(maximum, pair.0.bound.lower.map { max(0, $0 - pair.1.value) } ?? 0,
            pair.0.bound.upper.map { max(0, pair.1.value - $0) } ?? 0)
    }
}

private func stationarityNorm(_ problem: ConstrainedNonlinearProblem, _ point: [Double],
                              _ objectiveGradient: [Double], _ values: [DifferentiableValue],
                              _ multipliers: [ConstraintMultiplier]) -> Double {
    var gradient = objectiveGradient
    for ((constraint, value), multiplier) in zip(zip(problem.constraints, values), multipliers) {
        if let lower = constraint.bound.lower, let upper = constraint.bound.upper, lower == upper {
            constrainedAdd(&gradient, value.gradient, multiplier.equality)
        } else {
            constrainedAdd(&gradient, value.gradient, multiplier.upper - multiplier.lower)
        }
    }
    for index in gradient.indices {
        if ((problem.model.bounds[index].lower.map { point[index] <= $0 } ?? false) && gradient[index] > 0)
            || ((problem.model.bounds[index].upper.map { point[index] >= $0 } ?? false) && gradient[index] < 0) {
            gradient[index] = 0
        }
    }
    return gradient.map(abs).max() ?? 0
}

private func constrainedAdd(_ target: inout [Double], _ source: [Double], _ scale: Double) {
    for index in target.indices { target[index] += scale * source[index] }
}
private func constrainedValidBound(_ bound: ParameterBound) -> Bool {
    (bound.lower?.isFinite ?? true) && (bound.upper?.isFinite ?? true)
        && (bound.lower ?? -.infinity) <= (bound.upper ?? .infinity)
}
