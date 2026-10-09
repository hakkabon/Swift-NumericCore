import Foundation

public struct FeasibilityRestorationOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var feasibilityTolerance: Double
    public var interiorMargin: Double

    public init(maxIterations: Int = 200, feasibilityTolerance: Double = 1e-7,
                interiorMargin: Double = 0) {
        self.maxIterations = maxIterations
        self.feasibilityTolerance = feasibilityTolerance
        self.interiorMargin = interiorMargin
    }
}

public enum FeasibilityRestorationTermination: Sendable, Hashable {
    case alreadyFeasible, converged, iterationLimit, stalled
}

public struct FeasibilityRestorationResult: Sendable, Hashable {
    public let point: [Double]
    public let maximumViolation: Double
    public let squaredViolation: Double
    public let iterations: Int
    public let evaluations: Int
    public let termination: FeasibilityRestorationTermination
}

/// Phase-I minimization of squared equality and active inequality violations.
/// A positive interior margin requests strict inequality feasibility for a
/// subsequent barrier solve.
public enum FeasibilityRestoration {
    public static func restore(problem: ConstrainedNonlinearProblem, initial: [Double],
                               options: FeasibilityRestorationOptions = .init())
        throws -> FeasibilityRestorationResult {
        try problem.validate()
        guard initial.count == problem.model.parameterCount,
              initial.allSatisfy(\.isFinite), options.maxIterations > 0,
              options.feasibilityTolerance.isFinite, options.feasibilityTolerance > 0,
              options.interiorMargin.isFinite, options.interiorMargin >= 0 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid restoration problem or options")
        }
        let bounds = try restorationBounds(problem.model.bounds, options.interiorMargin)
        let start = zip(initial, bounds).map { max($1.lower ?? -.infinity,
                                                   min($0, $1.upper ?? .infinity)) }
        let initialEvaluation = try violationEvaluation(problem, start, options.interiorMargin)
        let initialViolation = try maximumViolation(problem, start, options.interiorMargin)
        if initialViolation <= options.feasibilityTolerance {
            return .init(point: start, maximumViolation: initialViolation,
                         squaredViolation: initialEvaluation.value, iterations: 0,
                         evaluations: 1, termination: .alreadyFeasible)
        }
        let inner = LBFGSOptions(maxIterations: options.maxIterations,
                                 gradientTolerance: options.feasibilityTolerance,
                                 stepTolerance: 1e-12,
                                 objectiveTolerance: options.feasibilityTolerance * options.feasibilityTolerance)
        let solved = try LBFGSB.minimize(initial: start, bounds: bounds, options: inner) { point in
            let value = try violationEvaluation(problem, point, options.interiorMargin)
            return (value.value, value.gradient)
        }
        let violation = try maximumViolation(problem, solved.point, options.interiorMargin)
        let termination: FeasibilityRestorationTermination
        if violation <= options.feasibilityTolerance { termination = .converged }
        else if solved.termination == .iterationLimit { termination = .iterationLimit }
        else { termination = .stalled }
        return .init(point: solved.point, maximumViolation: violation,
                     squaredViolation: solved.objective, iterations: solved.iterations,
                     evaluations: solved.evaluations, termination: termination)
    }
}

private func violationEvaluation(_ problem: ConstrainedNonlinearProblem, _ point: [Double],
                                 _ margin: Double) throws -> DifferentiableValue {
    let values = try problem.evaluateConstraints(at: point)
    var merit = 0.0, gradient = [Double](repeating: 0, count: point.count)
    for (constraint, value) in zip(problem.constraints, values) {
        let equality = constraint.bound.lower != nil
            && constraint.bound.lower == constraint.bound.upper
        if equality {
            let residual = value.value - constraint.bound.lower!
            merit += 0.5 * residual * residual
            for index in gradient.indices { gradient[index] += residual * value.gradient[index] }
        } else {
            if let lower = constraint.bound.lower {
                let residual = max(0, lower + margin - value.value)
                merit += 0.5 * residual * residual
                for index in gradient.indices { gradient[index] -= residual * value.gradient[index] }
            }
            if let upper = constraint.bound.upper {
                let residual = max(0, value.value - (upper - margin))
                merit += 0.5 * residual * residual
                for index in gradient.indices { gradient[index] += residual * value.gradient[index] }
            }
        }
    }
    return .init(value: merit, gradient: gradient)
}

private func maximumViolation(_ problem: ConstrainedNonlinearProblem, _ point: [Double],
                              _ margin: Double) throws -> Double {
    let values = try problem.evaluateConstraints(at: point)
    return zip(problem.constraints, values).reduce(0) { maximum, pair in
        let bound = pair.0.bound, value = pair.1.value
        if bound.lower != nil, bound.lower == bound.upper {
            return max(maximum, abs(value - bound.lower!))
        }
        return max(maximum,
                   bound.lower.map { max(0, $0 + margin - value) } ?? 0,
                   bound.upper.map { max(0, value - ($0 - margin)) } ?? 0)
    }
}

private func restorationBounds(_ bounds: [ParameterBound], _ margin: Double) throws
    -> [ParameterBound] {
    try bounds.map { bound in
        let result = ParameterBound(lower: bound.lower.map { $0 + margin },
                                    upper: bound.upper.map { $0 - margin })
        guard (result.lower ?? -.infinity) <= (result.upper ?? .infinity) else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "variable bounds have no restoration interior")
        }
        return result
    }
}
