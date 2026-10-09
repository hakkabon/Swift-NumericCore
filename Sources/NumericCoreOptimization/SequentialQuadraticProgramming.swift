import Foundation

public struct SQPOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var feasibilityTolerance: Double
    public var stationarityTolerance: Double
    public var stepTolerance: Double
    public var meritPenalty: Double
    public var penaltyIncrease: Double
    public var armijo: Double
    public var backtracking: Double
    public var maxLineSearchIterations: Int
    public var hessianRegularization: Double
    public var qpOptions: QuadraticOptions
    public var restoration: Bool
    public var restorationOptions: FeasibilityRestorationOptions
    public var globalization: SQPGlobalization
    public var filterConstraintMargin: Double
    public var filterObjectiveMargin: Double

    public init(maxIterations: Int = 100, feasibilityTolerance: Double = 1e-7,
                stationarityTolerance: Double = 1e-6, stepTolerance: Double = 1e-10,
                meritPenalty: Double = 10, penaltyIncrease: Double = 10,
                armijo: Double = 1e-4, backtracking: Double = 0.5,
                maxLineSearchIterations: Int = 30, hessianRegularization: Double = 1e-8,
                qpOptions: QuadraticOptions = .init(), restoration: Bool = false,
                restorationOptions: FeasibilityRestorationOptions = .init(),
                globalization: SQPGlobalization = .merit,
                filterConstraintMargin: Double = 1e-4,
                filterObjectiveMargin: Double = 1e-4) {
        self.maxIterations = maxIterations
        self.feasibilityTolerance = feasibilityTolerance
        self.stationarityTolerance = stationarityTolerance
        self.stepTolerance = stepTolerance
        self.meritPenalty = meritPenalty
        self.penaltyIncrease = penaltyIncrease
        self.armijo = armijo
        self.backtracking = backtracking
        self.maxLineSearchIterations = maxLineSearchIterations
        self.hessianRegularization = hessianRegularization
        self.qpOptions = qpOptions
        self.restoration = restoration
        self.restorationOptions = restorationOptions
        self.globalization = globalization
        self.filterConstraintMargin = filterConstraintMargin
        self.filterObjectiveMargin = filterObjectiveMargin
    }
}

public enum SQPGlobalization: Sendable, Hashable { case merit, filter }

public enum SQPTermination: Sendable, Hashable {
    case converged, iterationLimit, stepLimit, lineSearchFailed, qpFailure
    case restorationFailed, cancelled
}

public struct SQPResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let constraintValues: [Double]
    public let multipliers: [ConstraintMultiplier]
    public let maximumViolation: Double
    public let stationarityNorm: Double
    public let iterations: Int
    public let evaluations: Int
    public let acceptedSteps: Int
    public let rejectedSteps: Int
    public let finalMeritPenalty: Double
    public let lastStepNorm: Double
    public let termination: SQPTermination
}

public struct SQPIteration: Sendable, Hashable {
    public let iteration: Int
    public let objective: Double
    public let maximumViolation: Double
    public let stationarityNorm: Double
    public let stepNorm: Double
    public let stepLength: Double
    public let meritPenalty: Double
}

public enum SequentialQuadraticProgramming {
    public typealias Observer = (SQPIteration) -> Bool

    public static func minimize(problem: ConstrainedNonlinearProblem, initial: [Double],
                                options: SQPOptions = .init(), observer: Observer? = nil)
        throws -> SQPResult {
        try problem.validate(); try sqpValidate(options)
        guard initial.count == problem.model.parameterCount, initial.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        let n = initial.count
        var point = sqpProject(initial, problem.model.bounds)
        var restorationEvaluations = 0
        let initialConstraints = try problem.evaluateConstraints(at: point)
        if options.restoration,
           sqpMaximumViolation(problem, initialConstraints) > options.feasibilityTolerance {
            let restored = try FeasibilityRestoration.restore(
                problem: problem, initial: point, options: options.restorationOptions)
            restorationEvaluations = restored.evaluations
            point = restored.point
            if restored.maximumViolation > options.feasibilityTolerance
                || restored.termination == .iterationLimit || restored.termination == .stalled {
                let objective = try problem.model.evaluateObjective(parameters: point)
                let constraints = try problem.evaluateConstraints(at: point)
                return sqpResult(problem, point, objective, constraints,
                                 [ConstraintMultiplier](repeating: .init(),
                                                        count: problem.constraints.count),
                                 0, restored.evaluations, 0, 0, options.meritPenalty, 0,
                                 .restorationFailed)
            }
        }
        var objective = try problem.model.evaluateObjective(parameters: point)
        var constraints = try problem.evaluateConstraints(at: point)
        var evaluations = 1 + restorationEvaluations
        var hessian = sqpIdentity(n)
        var multipliers = [ConstraintMultiplier](repeating: .init(), count: problem.constraints.count)
        var penalty = options.meritPenalty
        var acceptedSteps = 0, rejectedSteps = 0
        var lastStepNorm = 0.0
        var filter = [(sqpViolationSum(problem, constraints), objective.value)]

        for iteration in 1...options.maxIterations {
            let violation = sqpMaximumViolation(problem, constraints)
            let stationarity = sqpStationarity(problem, point, objective.gradient,
                                                constraints, multipliers)
            if violation <= options.feasibilityTolerance,
               stationarity <= options.stationarityTolerance {
                return sqpResult(problem, point, objective, constraints, multipliers,
                                 iteration - 1, evaluations, acceptedSteps, rejectedSteps,
                                 penalty, lastStepNorm, .converged)
            }
            sqpRegularize(&hessian, options.hessianRegularization)
            let subproblem = try sqpSubproblem(problem, point, objective.gradient,
                                               constraints, hessian)
            let qp = try ConvexQuadraticSolver.solve(subproblem, options: options.qpOptions)
            if qp.termination != .converged {
                return sqpResult(problem, point, objective, constraints, multipliers,
                                 iteration - 1, evaluations, acceptedSteps, rejectedSteps,
                                 penalty, lastStepNorm, .qpFailure)
            }
            let step = qp.point
            lastStepNorm = sqpInfinity(step)
            let candidateMultipliers = sqpMultipliers(problem, qp.rowDual)
            let multiplierScale = candidateMultipliers.reduce(0) {
                max($0, abs($1.lower), abs($1.upper), abs($1.equality))
            }
            if penalty <= multiplierScale {
                penalty = max(penalty * options.penaltyIncrease, 1.1 * multiplierScale)
            }
            if lastStepNorm <= options.stepTolerance {
                multipliers = candidateMultipliers
                let currentStationarity = sqpStationarity(
                    problem, point, objective.gradient, constraints, multipliers)
                let termination: SQPTermination = violation <= options.feasibilityTolerance
                    && currentStationarity <= options.stationarityTolerance ? .converged : .stepLimit
                return sqpResult(problem, point, objective, constraints, multipliers,
                                 iteration, evaluations, acceptedSteps, rejectedSteps,
                                 penalty, lastStepNorm, termination)
            }
            let currentMerit = objective.value + penalty * sqpViolationSum(problem, constraints)
            let predicted = max(1e-12, sqpPredictedReduction(
                problem, objective.gradient, constraints, hessian, step, penalty))
            let oldLagrangian = sqpLagrangian(
                problem, objective.gradient, constraints, candidateMultipliers)
            var alpha = 1.0
            var accepted: ([Double], DifferentiableValue, [DifferentiableValue])?
            for _ in 0..<options.maxLineSearchIterations {
                let trial = sqpProject(zip(point, step).map { $0 + alpha * $1 }, problem.model.bounds)
                let trialObjective = try problem.model.evaluateObjective(parameters: trial)
                let trialConstraints = try problem.evaluateConstraints(at: trial)
                evaluations += 1
                let trialMerit = trialObjective.value
                    + penalty * sqpViolationSum(problem, trialConstraints)
                let trialViolation = sqpViolationSum(problem, trialConstraints)
                let currentViolation = sqpViolationSum(problem, constraints)
                let acceptedByMerit = trialMerit
                    <= currentMerit - options.armijo * alpha * predicted
                let acceptedByFilter = filter.allSatisfy { violation, value in
                    trialViolation <= (1 - options.filterConstraintMargin) * violation
                        || trialObjective.value <= value - options.filterObjectiveMargin * violation
                }
                let accept: Bool
                switch options.globalization {
                case .merit: accept = acceptedByMerit
                case .filter where currentViolation <= options.feasibilityTolerance:
                    accept = acceptedByMerit
                case .filter:
                    accept = acceptedByFilter
                        && (trialViolation < currentViolation || acceptedByMerit)
                }
                if accept {
                    accepted = (trial, trialObjective, trialConstraints); break
                }
                rejectedSteps += 1; alpha *= options.backtracking
            }
            guard let (newPoint, newObjective, newConstraints) = accepted else {
                return sqpResult(problem, point, objective, constraints, multipliers,
                                 iteration - 1, evaluations, acceptedSteps, rejectedSteps,
                                 penalty, lastStepNorm, .lineSearchFailed)
            }
            acceptedSteps += 1
            if options.globalization == .filter {
                let newPair = (sqpViolationSum(problem, newConstraints), newObjective.value)
                filter.removeAll { violation, value in
                    violation >= newPair.0 && value >= newPair.1
                }
                filter.append(newPair)
            }
            let actualStep = zip(newPoint, point).map(-)
            let newLagrangian = sqpLagrangian(
                problem, newObjective.gradient, newConstraints, candidateMultipliers)
            let y = zip(newLagrangian, oldLagrangian).map(-)
            sqpBFGS(&hessian, actualStep, y, options.hessianRegularization)
            point = newPoint; objective = newObjective; constraints = newConstraints
            multipliers = candidateMultipliers
            let newViolation = sqpMaximumViolation(problem, constraints)
            let newStationarity = sqpStationarity(
                problem, point, objective.gradient, constraints, multipliers)
            if observer?(.init(iteration: iteration, objective: objective.value,
                               maximumViolation: newViolation,
                               stationarityNorm: newStationarity,
                               stepNorm: sqpInfinity(actualStep), stepLength: alpha,
                               meritPenalty: penalty)) == false {
                return sqpResult(problem, point, objective, constraints, multipliers,
                                 iteration, evaluations, acceptedSteps, rejectedSteps,
                                 penalty, sqpInfinity(actualStep), .cancelled)
            }
        }
        return sqpResult(problem, point, objective, constraints, multipliers,
                         options.maxIterations, evaluations, acceptedSteps, rejectedSteps,
                         penalty, lastStepNorm, .iterationLimit)
    }
}

private func sqpSubproblem(_ problem: ConstrainedNonlinearProblem, _ point: [Double],
                           _ gradient: [Double], _ values: [DifferentiableValue],
                           _ hessian: [[Double]]) throws -> QuadraticProblem {
    var rowPointers = [0], columns: [Int] = [], entries: [Double] = []
    for value in values {
        for (column, entry) in value.gradient.enumerated() where entry != 0 {
            columns.append(column); entries.append(entry)
        }
        rowPointers.append(entries.count)
    }
    let matrix = try QuadraticConstraintMatrix(
        rows: values.count, columns: point.count, rowPointers: rowPointers,
        columnIndices: columns, values: entries)
    let rowBounds = zip(problem.constraints, values).map { constraint, value in
        ParameterBound(lower: constraint.bound.lower.map { $0 - value.value },
                       upper: constraint.bound.upper.map { $0 - value.value })
    }
    let variableBounds = zip(problem.model.bounds, point).map { bound, value in
        ParameterBound(lower: bound.lower.map { $0 - value },
                       upper: bound.upper.map { $0 - value })
    }
    return .init(quadratic: hessian, linear: gradient, constraints: matrix,
                 rowBounds: rowBounds, variableBounds: variableBounds)
}

private func sqpMultipliers(_ problem: ConstrainedNonlinearProblem,
                            _ duals: [Double]) -> [ConstraintMultiplier] {
    zip(problem.constraints, duals).map { constraint, dual in
        if constraint.bound.lower != nil, constraint.bound.lower == constraint.bound.upper {
            return .init(equality: dual)
        }
        return .init(lower: max(0, -dual), upper: max(0, dual))
    }
}

private func sqpPredictedReduction(_ problem: ConstrainedNonlinearProblem,
                                   _ gradient: [Double], _ values: [DifferentiableValue],
                                   _ hessian: [[Double]], _ step: [Double],
                                   _ penalty: Double) -> Double {
    let linearized = values.map {
        DifferentiableValue(value: $0.value + sqpDot($0.gradient, step), gradient: [])
    }
    let modelChange = sqpDot(gradient, step)
        + 0.5 * sqpDot(step, sqpMatvec(hessian, step))
    return -(modelChange + penalty * (sqpViolationSum(problem, linearized)
                                      - sqpViolationSum(problem, values)))
}

private func sqpViolationSum(_ problem: ConstrainedNonlinearProblem,
                             _ values: [DifferentiableValue]) -> Double {
    zip(problem.constraints, values).reduce(0) { sum, pair in
        let bound = pair.0.bound, value = pair.1.value
        if let lower = bound.lower, lower == bound.upper { return sum + abs(value - lower) }
        return sum + (bound.lower.map { max(0, $0 - value) } ?? 0)
            + (bound.upper.map { max(0, value - $0) } ?? 0)
    }
}

private func sqpMaximumViolation(_ problem: ConstrainedNonlinearProblem,
                                 _ values: [DifferentiableValue]) -> Double {
    zip(problem.constraints, values).reduce(0) { result, pair in
        max(result, pair.0.bound.lower.map { max(0, $0 - pair.1.value) } ?? 0,
            pair.0.bound.upper.map { max(0, pair.1.value - $0) } ?? 0)
    }
}

private func sqpLagrangian(_ problem: ConstrainedNonlinearProblem, _ objective: [Double],
                           _ values: [DifferentiableValue],
                           _ multipliers: [ConstraintMultiplier]) -> [Double] {
    var result = objective
    for ((constraint, value), multiplier) in zip(zip(problem.constraints, values), multipliers) {
        let scale = constraint.bound.lower != nil && constraint.bound.lower == constraint.bound.upper
            ? multiplier.equality : multiplier.upper - multiplier.lower
        for index in result.indices { result[index] += scale * value.gradient[index] }
    }
    return result
}

private func sqpStationarity(_ problem: ConstrainedNonlinearProblem, _ point: [Double],
                             _ objective: [Double], _ values: [DifferentiableValue],
                             _ multipliers: [ConstraintMultiplier]) -> Double {
    var result = sqpLagrangian(problem, objective, values, multipliers)
    for index in result.indices {
        if ((problem.model.bounds[index].lower.map { point[index] <= $0 + 1e-12 } ?? false)
            && result[index] > 0)
            || ((problem.model.bounds[index].upper.map { point[index] >= $0 - 1e-12 } ?? false)
                && result[index] < 0) { result[index] = 0 }
    }
    return sqpInfinity(result)
}

private func sqpBFGS(_ hessian: inout [[Double]], _ step: [Double], _ y: [Double],
                     _ regularization: Double) {
    let bs = sqpMatvec(hessian, step), sbs = sqpDot(step, bs), sy = sqpDot(step, y)
    let scale = max(1, sqpInfinity(step)) * max(1, sqpInfinity(y))
    guard sbs.isFinite, sy.isFinite, sbs > regularization, sy > 1e-10 * scale else {
        hessian = sqpIdentity(step.count); return
    }
    for i in step.indices { for j in step.indices {
        hessian[i][j] += y[i] * y[j] / sy - bs[i] * bs[j] / sbs
    }}
    sqpRegularize(&hessian, regularization)
}

private func sqpResult(_ problem: ConstrainedNonlinearProblem, _ point: [Double],
                       _ objective: DifferentiableValue, _ constraints: [DifferentiableValue],
                       _ multipliers: [ConstraintMultiplier], _ iterations: Int,
                       _ evaluations: Int, _ accepted: Int, _ rejected: Int,
                       _ penalty: Double, _ stepNorm: Double,
                       _ termination: SQPTermination) -> SQPResult {
    .init(point: point, objective: objective.value, constraintValues: constraints.map(\.value),
          multipliers: multipliers, maximumViolation: sqpMaximumViolation(problem, constraints),
          stationarityNorm: sqpStationarity(
            problem, point, objective.gradient, constraints, multipliers),
          iterations: iterations, evaluations: evaluations, acceptedSteps: accepted,
          rejectedSteps: rejected, finalMeritPenalty: penalty,
          lastStepNorm: stepNorm, termination: termination)
}

private func sqpValidate(_ options: SQPOptions) throws {
    guard options.maxIterations > 0, options.maxLineSearchIterations > 0,
          options.feasibilityTolerance.isFinite, options.feasibilityTolerance > 0,
          options.stationarityTolerance.isFinite, options.stationarityTolerance > 0,
          options.stepTolerance.isFinite, options.stepTolerance > 0,
          options.meritPenalty.isFinite, options.meritPenalty > 0,
          options.penaltyIncrease.isFinite, options.penaltyIncrease > 1,
          options.armijo.isFinite, options.armijo > 0, options.armijo < 1,
          options.backtracking.isFinite, options.backtracking > 0, options.backtracking < 1,
          options.hessianRegularization.isFinite, options.hessianRegularization > 0,
          options.filterConstraintMargin.isFinite, options.filterConstraintMargin > 0,
          options.filterConstraintMargin < 1, options.filterObjectiveMargin.isFinite,
          options.filterObjectiveMargin > 0 else {
        throw NonlinearOptimizationError.invalidConfiguration("invalid SQP options")
    }
}

private func sqpIdentity(_ count: Int) -> [[Double]] {
    var result = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
    for index in 0..<count { result[index][index] = 1 }
    return result
}
private func sqpRegularize(_ hessian: inout [[Double]], _ value: Double) {
    for index in hessian.indices { hessian[index][index] = max(hessian[index][index], value) }
}
private func sqpProject(_ point: [Double], _ bounds: [ParameterBound]) -> [Double] {
    zip(point, bounds).map { max($1.lower ?? -.infinity, min($0, $1.upper ?? .infinity)) }
}
private func sqpDot(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
}
private func sqpMatvec(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
    matrix.map { sqpDot($0, vector) }
}
private func sqpInfinity(_ values: [Double]) -> Double { values.map(abs).max() ?? 0 }
