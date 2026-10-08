import Foundation

public enum NonlinearRelaxationStrategy: Sendable, Hashable {
    case sqp, augmentedLagrangian
}

public struct MixedIntegerNonlinearOptions: Sendable, Hashable {
    public var maxNodes: Int
    public var integerTolerance: Double
    public var feasibilityTolerance: Double
    public var absoluteGapTolerance: Double
    public var relativeGapTolerance: Double
    public var relaxationStrategy: NonlinearRelaxationStrategy
    public var sqpOptions: SQPOptions
    public var constrainedOptions: ConstrainedOptions
    public var unconstrainedOptions: LBFGSOptions

    public init(maxNodes: Int = 1_000, integerTolerance: Double = 1e-7,
                feasibilityTolerance: Double = 1e-7,
                absoluteGapTolerance: Double = 0, relativeGapTolerance: Double = 0,
                relaxationStrategy: NonlinearRelaxationStrategy = .sqp,
                sqpOptions: SQPOptions = .init(),
                constrainedOptions: ConstrainedOptions = .init(),
                unconstrainedOptions: LBFGSOptions = .init()) {
        self.maxNodes = maxNodes; self.integerTolerance = integerTolerance
        self.feasibilityTolerance = feasibilityTolerance
        self.absoluteGapTolerance = absoluteGapTolerance
        self.relativeGapTolerance = relativeGapTolerance
        self.relaxationStrategy = relaxationStrategy; self.sqpOptions = sqpOptions
        self.constrainedOptions = constrainedOptions
        self.unconstrainedOptions = unconstrainedOptions
    }
}

public struct MixedIntegerNonlinearProblem: Sendable, Hashable {
    public let model: NonlinearModel
    public let constraints: [NonlinearConstraint]
    public let isInteger: [Bool]

    public init(model: NonlinearModel, constraints: [NonlinearConstraint],
                isInteger: [Bool]) throws {
        self.model = model; self.constraints = constraints; self.isInteger = isInteger
        try validate()
    }

    public func validate() throws {
        try model.validate()
        guard model.objective != nil, isInteger.count == model.parameterCount,
              isInteger.contains(true) else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "MINLP requires an objective and one integrality flag per parameter")
        }
        if !constraints.isEmpty {
            _ = try ConstrainedNonlinearProblem(model: model, constraints: constraints)
        }
    }
}

public enum MixedIntegerNonlinearTermination: Sendable, Hashable {
    case searchExhausted, localGapLimit, nodeLimit, infeasible, relaxationFailure, cancelled
}

public struct MixedIntegerNonlinearResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let constraintValues: [Double]
    public let multipliers: [ConstraintMultiplier]
    public let maximumViolation: Double
    public let stationarityNorm: Double
    public let nodesExplored: Int
    public let relaxationsSolved: Int
    public let nodesPrunedInfeasible: Int
    public let maximumDepth: Int
    public let incumbentsFound: Int
    public let bestRelaxationObjective: Double?
    public let absoluteGap: Double?
    public let relativeGap: Double?
    public let globalOptimalityCertified: Bool
    public let termination: MixedIntegerNonlinearTermination
}

public struct MixedIntegerNonlinearIteration: Sendable, Hashable {
    public let nodesExplored: Int
    public let depth: Int
    public let relaxationObjective: Double
    public let incumbentObjective: Double?
}

public enum MixedIntegerNonlinearSolver {
    public typealias Observer = (MixedIntegerNonlinearIteration) -> Bool

    public static func minimize(
        problem: MixedIntegerNonlinearProblem, initial: [Double],
        options: MixedIntegerNonlinearOptions = .init(), observer: Observer? = nil
    ) throws -> MixedIntegerNonlinearResult {
        try problem.validate(); try minlpValidate(options)
        guard initial.count == problem.model.parameterCount,
              initial.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        var nodes = [MINLPNode(bounds: problem.model.bounds,
                               start: minlpClamp(initial, problem.model.bounds), depth: 0)]
        var incumbent: MINLPRelaxation?
        var explored = 0, solved = 0, pruned = 0, maximumDepth = 0, incumbents = 0
        var failures = 0, bestRelaxation: Double?
        var localGapReached = false
        while !nodes.isEmpty {
            if explored >= options.maxNodes { break }
            let node = nodes.removeLast(); explored += 1
            maximumDepth = max(maximumDepth, node.depth)
            guard let relaxation = try minlpRelax(problem, node, options) else {
                pruned += 1; failures += 1; continue
            }
            solved += 1
            bestRelaxation = min(bestRelaxation ?? relaxation.objective, relaxation.objective)
            if observer?(.init(nodesExplored: explored, depth: node.depth,
                               relaxationObjective: relaxation.objective,
                               incumbentObjective: incumbent?.objective)) == false {
                return minlpResult(incumbent, explored, solved, pruned, maximumDepth,
                                   incumbents, bestRelaxation, .cancelled)
            }
            if relaxation.violation > options.feasibilityTolerance { pruned += 1; continue }
            if let index = minlpBranchIndex(problem, relaxation.point,
                                            options.integerTolerance) {
                let value = relaxation.point[index]
                var lowerBounds = node.bounds, upperBounds = node.bounds
                let lowerValid = minlpTightenUpper(&lowerBounds[index], floor(value))
                let upperValid = minlpTightenLower(&upperBounds[index], ceil(value))
                if upperValid {
                    nodes.append(.init(bounds: upperBounds,
                        start: minlpClamp(relaxation.point, upperBounds), depth: node.depth + 1))
                }
                if lowerValid {
                    nodes.append(.init(bounds: lowerBounds,
                        start: minlpClamp(relaxation.point, lowerBounds), depth: node.depth + 1))
                }
            } else {
                guard let candidate = try minlpSnappedCandidate(
                    problem, relaxation, options.feasibilityTolerance) else {
                    pruned += 1; continue
                }
                if incumbent == nil || candidate.objective < incumbent!.objective {
                    incumbent = candidate; incumbents += 1
                }
                if let incumbent, let bestRelaxation {
                    let gap = max(0, incumbent.objective - bestRelaxation)
                    let relative = gap / max(abs(incumbent.objective), 1)
                    if (options.absoluteGapTolerance > 0
                        && gap <= options.absoluteGapTolerance)
                        || (options.relativeGapTolerance > 0
                            && relative <= options.relativeGapTolerance) {
                        localGapReached = true; break
                    }
                }
            }
        }
        let termination: MixedIntegerNonlinearTermination
        if incumbent == nil {
            termination = solved == 0 && failures > 0 ? .relaxationFailure : .infeasible
        } else if localGapReached { termination = .localGapLimit
        } else { termination = nodes.isEmpty ? .searchExhausted : .nodeLimit }
        return minlpResult(incumbent, explored, solved, pruned, maximumDepth,
                           incumbents, bestRelaxation, termination)
    }
}

private struct MINLPNode { var bounds: [ParameterBound]; var start: [Double]; var depth: Int }
private struct MINLPRelaxation {
    var point: [Double]; var objective: Double; var values: [Double]
    var multipliers: [ConstraintMultiplier]; var violation: Double; var stationarity: Double
}

private func minlpRelax(_ problem: MixedIntegerNonlinearProblem, _ node: MINLPNode,
                        _ options: MixedIntegerNonlinearOptions) throws -> MINLPRelaxation? {
    guard let objective = problem.model.objective else { return nil }
    let model = try NonlinearModel.objective(
        parameterCount: problem.model.parameterCount, bounds: node.bounds, expression: objective)
    if problem.constraints.isEmpty {
        let value = try LBFGSB.minimize(
            model: model, initial: node.start, options: options.unconstrainedOptions)
        guard value.termination == .convergedGradient
                || value.termination == .convergedStep
                || value.termination == .convergedObjective else { return nil }
        return .init(point: value.point, objective: value.objective, values: [], multipliers: [],
                     violation: 0, stationarity: value.gradientNorm)
    }
    let constrained = try ConstrainedNonlinearProblem(
        model: model, constraints: problem.constraints)
    switch options.relaxationStrategy {
    case .sqp:
        let value = try SequentialQuadraticProgramming.minimize(
            problem: constrained, initial: node.start, options: options.sqpOptions)
        guard value.termination == .converged else { return nil }
        return .init(point: value.point, objective: value.objective,
                     values: value.constraintValues, multipliers: value.multipliers,
                     violation: value.maximumViolation, stationarity: value.stationarityNorm)
    case .augmentedLagrangian:
        let value = try ConstrainedNonlinearSolver.minimize(
            problem: constrained, initial: node.start, options: options.constrainedOptions)
        guard value.termination == .converged else { return nil }
        return .init(point: value.point, objective: value.objective,
                     values: value.constraintValues, multipliers: value.multipliers,
                     violation: value.maximumViolation, stationarity: value.stationarityNorm)
    }
}

private func minlpBranchIndex(_ problem: MixedIntegerNonlinearProblem, _ point: [Double],
                              _ tolerance: Double) -> Int? {
    zip(problem.isInteger, point).enumerated().compactMap { index, pair -> (Int, Double)? in
        guard pair.0 else { return nil }
        let fractionality = abs(pair.1 - pair.1.rounded())
        return fractionality > tolerance ? (index, fractionality) : nil
    }.max { $0.1 < $1.1 }?.0
}

private func minlpSnappedCandidate(
    _ problem: MixedIntegerNonlinearProblem, _ source: MINLPRelaxation, _ tolerance: Double
) throws -> MINLPRelaxation? {
    var value = source
    for index in value.point.indices where problem.isInteger[index] {
        value.point[index] = value.point[index].rounded()
    }
    for (point, bound) in zip(value.point, problem.model.bounds) {
        if let lower = bound.lower, point < lower - tolerance { return nil }
        if let upper = bound.upper, point > upper + tolerance { return nil }
    }
    let objective = try problem.model.evaluateObjective(parameters: value.point)
    let evaluated = try problem.constraints.map { try $0.expression.evaluate(parameters: value.point) }
    let violation = zip(problem.constraints, evaluated).reduce(0.0) { maximum, pair in
        max(maximum,
            pair.0.bound.lower.map { max(0, $0 - pair.1.value) } ?? 0,
            pair.0.bound.upper.map { max(0, pair.1.value - $0) } ?? 0)
    }
    guard violation <= tolerance else { return nil }
    value.objective = objective.value; value.values = evaluated.map(\.value)
    value.violation = violation
    return value
}

private func minlpResult(
    _ incumbent: MINLPRelaxation?, _ nodes: Int, _ relaxations: Int, _ pruned: Int,
    _ depth: Int, _ incumbents: Int, _ best: Double?,
    _ termination: MixedIntegerNonlinearTermination
) -> MixedIntegerNonlinearResult {
    let gap = incumbent.flatMap { value in best.map { max(0, value.objective - $0) } }
    let relative = incumbent.flatMap { value in gap.map { $0 / max(abs(value.objective), 1) } }
    return .init(point: incumbent?.point ?? [], objective: incumbent?.objective ?? .nan,
                 constraintValues: incumbent?.values ?? [], multipliers: incumbent?.multipliers ?? [],
                 maximumViolation: incumbent?.violation ?? .infinity,
                 stationarityNorm: incumbent?.stationarity ?? .infinity,
                 nodesExplored: nodes, relaxationsSolved: relaxations,
                 nodesPrunedInfeasible: pruned, maximumDepth: depth,
                 incumbentsFound: incumbents, bestRelaxationObjective: best,
                 absoluteGap: gap, relativeGap: relative,
                 globalOptimalityCertified: false, termination: termination)
}

private func minlpClamp(_ point: [Double], _ bounds: [ParameterBound]) -> [Double] {
    zip(point, bounds).map { value, bound in
        min(max(value, bound.lower ?? -.infinity), bound.upper ?? .infinity)
    }
}
private func minlpTightenLower(_ bound: inout ParameterBound, _ value: Double) -> Bool {
    bound.lower = max(bound.lower ?? -.infinity, value)
    return bound.lower! <= (bound.upper ?? .infinity)
}
private func minlpTightenUpper(_ bound: inout ParameterBound, _ value: Double) -> Bool {
    bound.upper = min(bound.upper ?? .infinity, value)
    return (bound.lower ?? -.infinity) <= bound.upper!
}
private func minlpValidate(_ options: MixedIntegerNonlinearOptions) throws {
    guard options.maxNodes > 0, options.integerTolerance.isFinite,
          options.integerTolerance > 0, options.feasibilityTolerance.isFinite,
          options.feasibilityTolerance > 0, options.absoluteGapTolerance.isFinite,
          options.absoluteGapTolerance >= 0, options.relativeGapTolerance.isFinite,
          options.relativeGapTolerance >= 0 else {
        throw NonlinearOptimizationError.invalidConfiguration("invalid MINLP options")
    }
}
