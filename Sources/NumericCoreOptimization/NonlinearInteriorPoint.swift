import Foundation

/// Controls the feasible-start primal-dual barrier method.
public struct NonlinearInteriorPointOptions: Sendable, Hashable {
    public var maxOuterIterations: Int
    public var maxInnerIterations: Int
    public var feasibilityTolerance: Double
    public var stationarityTolerance: Double
    public var complementarityTolerance: Double
    public var initialBarrier: Double
    public var barrierReduction: Double
    public var minimumBarrier: Double
    public var equalityPenalty: Double
    public var armijo: Double
    public var backtracking: Double
    public var fractionToBoundary: Double
    public var maxLineSearchIterations: Int

    public init(maxOuterIterations: Int = 50, maxInnerIterations: Int = 100,
                feasibilityTolerance: Double = 1e-7,
                stationarityTolerance: Double = 1e-4,
                complementarityTolerance: Double = 1e-7,
                initialBarrier: Double = 0.1, barrierReduction: Double = 0.2,
                minimumBarrier: Double = 1e-7, equalityPenalty: Double = 10,
                armijo: Double = 1e-4, backtracking: Double = 0.5,
                fractionToBoundary: Double = 0.995,
                maxLineSearchIterations: Int = 40) {
        self.maxOuterIterations = maxOuterIterations
        self.maxInnerIterations = maxInnerIterations
        self.feasibilityTolerance = feasibilityTolerance
        self.stationarityTolerance = stationarityTolerance
        self.complementarityTolerance = complementarityTolerance
        self.initialBarrier = initialBarrier
        self.barrierReduction = barrierReduction
        self.minimumBarrier = minimumBarrier
        self.equalityPenalty = equalityPenalty
        self.armijo = armijo
        self.backtracking = backtracking
        self.fractionToBoundary = fractionToBoundary
        self.maxLineSearchIterations = maxLineSearchIterations
    }
}

public enum NonlinearInteriorPointTermination: Sendable, Hashable {
    case converged, iterationLimit, infeasibleStart, lineSearchFailed
    case numericalFailure, cancelled
}

public struct NonlinearInteriorPointResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let constraintValues: [Double]
    public let multipliers: [ConstraintMultiplier]
    public let maximumViolation: Double
    public let stationarityNorm: Double
    public let complementarity: Double
    public let outerIterations: Int
    public let innerIterations: Int
    public let evaluations: Int
    public let finalBarrier: Double
    public let acceptedSteps: Int
    public let rejectedSteps: Int
    public let termination: NonlinearInteriorPointTermination
}

public struct NonlinearInteriorPointIteration: Sendable, Hashable {
    public let outerIteration: Int
    public let innerIterations: Int
    public let objective: Double
    public let maximumViolation: Double
    public let stationarityNorm: Double
    public let complementarity: Double
    public let barrier: Double
}

/// A feasible-start interior-point method for graph-represented nonlinear programs.
/// Inequalities and variable bounds must be strictly feasible initially;
/// equalities may start infeasible and are handled by an augmented Lagrangian.
public enum NonlinearInteriorPointSolver {
    public typealias Observer = (NonlinearInteriorPointIteration) -> Bool

    public static func minimize(problem: ConstrainedNonlinearProblem, initial: [Double],
                                options: NonlinearInteriorPointOptions = .init(),
                                observer: Observer? = nil) throws -> NonlinearInteriorPointResult {
        try problem.validate()
        try ipValidate(options)
        guard initial.count == problem.model.parameterCount,
              initial.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        var point = initial
        let initialValues = try problem.evaluateConstraints(at: point)
        if !ipStrictInterior(problem, point, initialValues) {
            return try ipFinish(problem, point,
                                [Double](repeating: 0, count: ipEqualityCount(problem)),
                                0, 1, options.initialBarrier, 0, 0, .infeasibleStart)
        }
        var equalityMultipliers = [Double](repeating: 0, count: ipEqualityCount(problem))
        var barrier = options.initialBarrier
        var totalInner = 0, evaluations = 1, acceptedSteps = 0, rejectedSteps = 0
        for outer in 1...options.maxOuterIterations {
            var inverseHessian = ipIdentity(problem.model.parameterCount)
            for _ in 0..<options.maxInnerIterations {
                let current = try ipBarrierValueGradient(
                    problem, point, barrier, equalityMultipliers, options.equalityPenalty)
                let innerTolerance = min(options.stationarityTolerance,
                                         options.feasibilityTolerance * options.equalityPenalty)
                    .clampedBelow(by: 0.1 * barrier)
                if ipNorm(current.1) <= innerTolerance { break }
                var direction = ipMatvec(inverseHessian, current.1).map(-)
                if ipDot(current.1, direction) >= -1e-14 {
                    direction = current.1.map(-)
                    inverseHessian = ipIdentity(problem.model.parameterCount)
                }
                let slope = ipDot(current.1, direction)
                var alpha = min(options.fractionToBoundary, 1)
                var accepted: ([Double], (Double, [Double]))?
                for _ in 0..<options.maxLineSearchIterations {
                    let trial = zip(point, direction).map { $0 + alpha * $1 }
                    let values = try problem.evaluateConstraints(at: trial)
                    evaluations += 1
                    if ipStrictInterior(problem, trial, values) {
                        let evaluation = try ipBarrierValueGradient(
                            problem, trial, barrier, equalityMultipliers,
                            options.equalityPenalty)
                        if evaluation.0 <= current.0 + options.armijo * alpha * slope {
                            accepted = (trial, evaluation); break
                        }
                    }
                    rejectedSteps += 1; alpha *= options.backtracking
                }
                guard let accepted else { break }
                let step = zip(accepted.0, point).map(-)
                let y = zip(accepted.1.1, current.1).map(-)
                ipBFGSUpdate(&inverseHessian, step, y)
                point = accepted.0; totalInner += 1; acceptedSteps += 1
            }
            let objective = try problem.model.evaluateObjective(parameters: point)
            let values = try problem.evaluateConstraints(at: point)
            evaluations += 1
            ipUpdateEqualities(problem, values, &equalityMultipliers, options.equalityPenalty)
            let multipliers = ipRecoverMultipliers(problem, values, barrier, equalityMultipliers)
            let violation = ipMaximumViolation(problem, point, values)
            let stationarity = ipStationarity(
                problem, point, objective.gradient, values, multipliers, barrier)
            let complementarity = ipComplementarity(problem, values, multipliers, barrier)
            let snapshot = NonlinearInteriorPointIteration(
                outerIteration: outer, innerIterations: totalInner, objective: objective.value,
                maximumViolation: violation, stationarityNorm: stationarity,
                complementarity: complementarity, barrier: barrier)
            if observer?(snapshot) == false {
                return try ipFinish(problem, point, equalityMultipliers, outer, evaluations,
                                    barrier, acceptedSteps, rejectedSteps, .cancelled)
            }
            if violation <= options.feasibilityTolerance,
               stationarity <= options.stationarityTolerance,
               complementarity <= options.complementarityTolerance {
                return try ipFinish(problem, point, equalityMultipliers, outer, evaluations,
                                    barrier, acceptedSteps, rejectedSteps, .converged)
            }
            barrier = max(barrier * options.barrierReduction, options.minimumBarrier)
        }
        return try ipFinish(problem, point, equalityMultipliers, options.maxOuterIterations,
                            evaluations, barrier, acceptedSteps, rejectedSteps, .iterationLimit)
    }
}

private func ipBarrierValueGradient(
    _ problem: ConstrainedNonlinearProblem, _ point: [Double], _ barrier: Double,
    _ equalityMultipliers: [Double], _ equalityPenalty: Double
) throws -> (Double, [Double]) {
    let objective = try problem.model.evaluateObjective(parameters: point)
    let values = try problem.evaluateConstraints(at: point)
    var total = objective.value, gradient = objective.gradient, equality = 0
    for (constraint, value) in zip(problem.constraints, values) {
        if ipEquality(constraint.bound) {
            let residual = value.value - constraint.bound.lower!
            let coefficient = equalityMultipliers[equality] + equalityPenalty * residual
            total += equalityMultipliers[equality] * residual
                + 0.5 * equalityPenalty * residual * residual
            ipAdd(&gradient, value.gradient, coefficient); equality += 1
        } else {
            if let lower = constraint.bound.lower {
                let slack = value.value - lower
                guard slack > 0 else { throw NonlinearOptimizationError.invalidInitialPoint }
                total -= barrier * log(slack); ipAdd(&gradient, value.gradient, -barrier / slack)
            }
            if let upper = constraint.bound.upper {
                let slack = upper - value.value
                guard slack > 0 else { throw NonlinearOptimizationError.invalidInitialPoint }
                total -= barrier * log(slack); ipAdd(&gradient, value.gradient, barrier / slack)
            }
        }
    }
    for index in point.indices {
        if let lower = problem.model.bounds[index].lower {
            let slack = point[index] - lower
            guard slack > 0 else { throw NonlinearOptimizationError.invalidInitialPoint }
            total -= barrier * log(slack); gradient[index] -= barrier / slack
        }
        if let upper = problem.model.bounds[index].upper {
            let slack = upper - point[index]
            guard slack > 0 else { throw NonlinearOptimizationError.invalidInitialPoint }
            total -= barrier * log(slack); gradient[index] += barrier / slack
        }
    }
    return (total, gradient)
}

private func ipFinish(
    _ problem: ConstrainedNonlinearProblem, _ point: [Double], _ equalities: [Double],
    _ outer: Int, _ evaluations: Int, _ barrier: Double, _ accepted: Int, _ rejected: Int,
    _ termination: NonlinearInteriorPointTermination
) throws -> NonlinearInteriorPointResult {
    let objective = try problem.model.evaluateObjective(parameters: point)
    let values = try problem.evaluateConstraints(at: point)
    let multipliers = ipStrictInterior(problem, point, values)
        ? ipRecoverMultipliers(problem, values, barrier, equalities)
        : [ConstraintMultiplier](repeating: .init(), count: problem.constraints.count)
    return .init(point: point, objective: objective.value,
                 constraintValues: values.map(\.value), multipliers: multipliers,
                 maximumViolation: ipMaximumViolation(problem, point, values),
                 stationarityNorm: ipStationarity(
                    problem, point, objective.gradient, values, multipliers, barrier),
                 complementarity: ipComplementarity(problem, values, multipliers, barrier),
                 outerIterations: outer, innerIterations: accepted, evaluations: evaluations,
                 finalBarrier: barrier, acceptedSteps: accepted, rejectedSteps: rejected,
                 termination: termination)
}

private func ipStrictInterior(_ problem: ConstrainedNonlinearProblem, _ point: [Double],
                              _ values: [DifferentiableValue]) -> Bool {
    for index in point.indices {
        if let lower = problem.model.bounds[index].lower, point[index] <= lower { return false }
        if let upper = problem.model.bounds[index].upper, point[index] >= upper { return false }
    }
    for (constraint, value) in zip(problem.constraints, values) where !ipEquality(constraint.bound) {
        if let lower = constraint.bound.lower, value.value <= lower { return false }
        if let upper = constraint.bound.upper, value.value >= upper { return false }
    }
    return true
}

private func ipRecoverMultipliers(_ problem: ConstrainedNonlinearProblem,
                                  _ values: [DifferentiableValue], _ barrier: Double,
                                  _ equalities: [Double]) -> [ConstraintMultiplier] {
    var equality = 0
    return zip(problem.constraints, values).map { constraint, value in
        if ipEquality(constraint.bound) {
            defer { equality += 1 }
            return .init(equality: equalities[equality])
        }
        return .init(lower: constraint.bound.lower.map { barrier / (value.value - $0) } ?? 0,
                     upper: constraint.bound.upper.map { barrier / ($0 - value.value) } ?? 0)
    }
}

private func ipUpdateEqualities(_ problem: ConstrainedNonlinearProblem,
                                _ values: [DifferentiableValue], _ multipliers: inout [Double],
                                _ penalty: Double) {
    var index = 0
    for (constraint, value) in zip(problem.constraints, values) where ipEquality(constraint.bound) {
        multipliers[index] += penalty * (value.value - constraint.bound.lower!)
        index += 1
    }
}

private func ipMaximumViolation(_ problem: ConstrainedNonlinearProblem, _ point: [Double],
                                _ values: [DifferentiableValue]) -> Double {
    let constraintViolation = zip(problem.constraints, values).reduce(0) { result, pair in
        max(result, pair.0.bound.lower.map { max(0, $0 - pair.1.value) } ?? 0,
            pair.0.bound.upper.map { max(0, pair.1.value - $0) } ?? 0)
    }
    return zip(problem.model.bounds, point).reduce(constraintViolation) { result, pair in
        max(result, pair.0.lower.map { max(0, $0 - pair.1) } ?? 0,
            pair.0.upper.map { max(0, pair.1 - $0) } ?? 0)
    }
}

private func ipComplementarity(_ problem: ConstrainedNonlinearProblem,
                               _ values: [DifferentiableValue],
                               _ multipliers: [ConstraintMultiplier],
                               _ barrier: Double) -> Double {
    let constraintComplementarity = zip(zip(problem.constraints, values), multipliers)
        .reduce(0) { result, item in
        let (pair, multiplier) = item
        guard !ipEquality(pair.0.bound) else { return result }
        return max(result,
                   pair.0.bound.lower.map { multiplier.lower * (pair.1.value - $0) } ?? 0,
                   pair.0.bound.upper.map { multiplier.upper * ($0 - pair.1.value) } ?? 0)
    }
    return problem.model.bounds.contains { $0.lower != nil || $0.upper != nil }
        ? max(constraintComplementarity, barrier) : constraintComplementarity
}

private func ipStationarity(_ problem: ConstrainedNonlinearProblem, _ point: [Double],
                            _ objective: [Double], _ values: [DifferentiableValue],
                            _ multipliers: [ConstraintMultiplier], _ barrier: Double) -> Double {
    var gradient = objective
    for ((constraint, value), multiplier) in zip(zip(problem.constraints, values), multipliers) {
        ipAdd(&gradient, value.gradient, ipEquality(constraint.bound)
              ? multiplier.equality : multiplier.upper - multiplier.lower)
    }
    for index in point.indices {
        if let lower = problem.model.bounds[index].lower {
            gradient[index] -= barrier / (point[index] - lower)
        }
        if let upper = problem.model.bounds[index].upper {
            gradient[index] += barrier / (upper - point[index])
        }
    }
    return ipNorm(gradient)
}

private func ipBFGSUpdate(_ matrix: inout [[Double]], _ step: [Double], _ y: [Double]) {
    let sy = ipDot(step, y)
    guard sy.isFinite, sy > 1e-12 * max(ipNorm(step), 1) * max(ipNorm(y), 1) else { return }
    let hy = ipMatvec(matrix, y), coefficient = (sy + ipDot(y, hy)) / (sy * sy)
    for i in matrix.indices { for j in matrix.indices {
        matrix[i][j] += coefficient * step[i] * step[j]
            - (hy[i] * step[j] + step[i] * hy[j]) / sy
    }}
}

private func ipEquality(_ bound: ParameterBound) -> Bool {
    bound.lower != nil && bound.lower == bound.upper
}
private func ipEqualityCount(_ problem: ConstrainedNonlinearProblem) -> Int {
    problem.constraints.filter { ipEquality($0.bound) }.count
}
private func ipIdentity(_ count: Int) -> [[Double]] {
    (0..<count).map { row in (0..<count).map { row == $0 ? 1 : 0 } }
}
private func ipMatvec(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
    matrix.map { ipDot($0, vector) }
}
private func ipDot(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}
private func ipNorm(_ values: [Double]) -> Double { values.map(abs).max() ?? 0 }
private func ipAdd(_ target: inout [Double], _ source: [Double], _ scale: Double) {
    for index in target.indices { target[index] += scale * source[index] }
}
private func ipValidate(_ options: NonlinearInteriorPointOptions) throws {
    guard options.maxOuterIterations > 0, options.maxInnerIterations > 0,
          options.maxLineSearchIterations > 0,
          options.feasibilityTolerance.isFinite, options.feasibilityTolerance > 0,
          options.stationarityTolerance.isFinite, options.stationarityTolerance > 0,
          options.complementarityTolerance.isFinite, options.complementarityTolerance > 0,
          options.initialBarrier.isFinite, options.initialBarrier > 0,
          options.minimumBarrier.isFinite, options.minimumBarrier > 0,
          options.minimumBarrier <= options.initialBarrier,
          options.barrierReduction > 0, options.barrierReduction < 1,
          options.equalityPenalty.isFinite, options.equalityPenalty > 0,
          options.armijo > 0, options.armijo < 1,
          options.backtracking > 0, options.backtracking < 1,
          options.fractionToBoundary > 0, options.fractionToBoundary < 1 else {
        throw NonlinearOptimizationError.invalidConfiguration(
            "invalid nonlinear interior-point options")
    }
}

private extension Double {
    func clampedBelow(by lower: Double) -> Double { max(self, lower) }
}
