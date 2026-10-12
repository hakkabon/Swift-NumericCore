import Foundation
import NCBindings

public enum SpatialTermination: Sendable, Hashable {
    case globalGap, searchExhausted, spatialResolution, nodeLimit, infeasible,
         relaxationFailure, cancelled
}

public struct SpatialBranchAndBoundOptions: Sendable, Hashable {
    public var maxNodes: Int
    public var minimumWidth: Double
    public var absoluteGapTolerance: Double
    public var relativeGapTolerance: Double
    public var feasibilityTolerance: Double
    public var simplexIterations: Int
    public var propagationPasses: Int
    public var propagationTolerance: Double
    public var localOptions: LBFGSOptions
    public var sqpOptions: SQPOptions

    public init(maxNodes: Int = 10_000, minimumWidth: Double = 1e-4,
                absoluteGapTolerance: Double = 1e-6,
                relativeGapTolerance: Double = 1e-6,
                feasibilityTolerance: Double = 1e-7,
                simplexIterations: Int = 10_000,
                propagationPasses: Int = 8,
                propagationTolerance: Double = 1e-10,
                localOptions: LBFGSOptions = .init(), sqpOptions: SQPOptions = .init()) {
        self.maxNodes = maxNodes; self.minimumWidth = minimumWidth
        self.absoluteGapTolerance = absoluteGapTolerance
        self.relativeGapTolerance = relativeGapTolerance
        self.feasibilityTolerance = feasibilityTolerance
        self.simplexIterations = simplexIterations
        self.propagationPasses = propagationPasses
        self.propagationTolerance = propagationTolerance
        self.localOptions = localOptions; self.sqpOptions = sqpOptions
    }
}

public struct SpatialBranchAndBoundProblem: Sendable, Hashable {
    public let model: NonlinearModel
    public let constraints: [NonlinearConstraint]

    public init(model: NonlinearModel, constraints: [NonlinearConstraint] = []) throws {
        self.model = model; self.constraints = constraints
        try validate()
    }

    public func validate() throws {
        try model.validate()
        guard model.objective != nil,
              model.bounds.allSatisfy({ bound in
                  guard let lower = bound.lower, let upper = bound.upper else { return false }
                  return lower.isFinite && upper.isFinite && lower <= upper
              }) else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "spatial branch-and-bound requires a scalar objective and finite parameter box")
        }
        for constraint in constraints {
            try constraint.expression.validate(parameterCount: model.parameterCount)
            guard constraint.bound.lower != nil || constraint.bound.upper != nil else {
                throw NonlinearOptimizationError.invalidConfiguration(
                    "each nonlinear constraint requires at least one bound")
            }
        }
        _ = try spatialCompileRelaxation(self, model.bounds)
    }
}

public struct SpatialBranchAndBoundResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let globalLowerBound: Double?
    public let absoluteGap: Double?
    public let relativeGap: Double?
    public let nodesExplored: Int
    public let relaxationsSolved: Int
    public let nodesPrunedByBound: Int
    public let nodesPrunedInfeasible: Int
    public let nodesPrunedByPropagation: Int
    public let propagationPasses: Int
    public let boundsTightened: Int
    public let localSolves: Int
    public let incumbentsFound: Int
    public let maximumDepth: Int
    public let globalOptimalityCertified: Bool
    public let termination: SpatialTermination
}

public struct SpatialIteration: Sendable, Hashable {
    public let nodesExplored: Int
    public let depth: Int
    public let relaxationBound: Double
    public let incumbentObjective: Double?
    public let openGlobalBound: Double
}

public enum SpatialBranchAndBoundSolver {
    public typealias Observer = (SpatialIteration) -> Bool

    public static func minimize(
        problem: SpatialBranchAndBoundProblem,
        options: SpatialBranchAndBoundOptions = .init(), observer: Observer? = nil
    ) throws -> SpatialBranchAndBoundResult {
        try problem.validate(); try spatialValidate(options)
        var nodes = [SpatialNode(bounds: problem.model.bounds,
                                 inheritedBound: -.infinity, depth: 0)]
        var incumbent: SpatialIncumbent?
        var unresolvedBound = Double.infinity
        var explored = 0, solved = 0, prunedBound = 0, prunedInfeasible = 0
        var prunedPropagation = 0, propagationPasses = 0, boundsTightened = 0
        var localSolves = 0, incumbents = 0, maximumDepth = 0
        var relaxationFailures = 0
        var cancelled = false, gapReached = false

        while !nodes.isEmpty && explored < options.maxNodes {
            let nodeIndex = nodes.indices.min {
                nodes[$0].inheritedBound < nodes[$1].inheritedBound
            }!
            var node = nodes.remove(at: nodeIndex)
            explored += 1; maximumDepth = max(maximumDepth, node.depth)
            let propagation = try propagateNonlinearBounds(
                model: problem.model, constraints: problem.constraints, bounds: node.bounds,
                objectiveCutoff: incumbent.map { $0.objective - options.absoluteGapTolerance },
                options: .init(maxPasses: options.propagationPasses,
                               tolerance: options.propagationTolerance))
            propagationPasses += propagation.passes
            boundsTightened += propagation.boundsTightened
            if propagation.infeasible {
                prunedInfeasible += 1; prunedPropagation += 1; continue
            }
            node.bounds = propagation.bounds
            let lp = try spatialCompileRelaxation(problem, node.bounds)
            let solution = try FFIKernels.solveLPSimplex(lp, options: .init(
                maxIterations: UInt64(options.simplexIterations),
                tolerance: min(1e-9, max(1e-12, options.feasibilityTolerance)),
                scaling: true))
            switch solution.status {
            case .infeasible: prunedInfeasible += 1; continue
            case .optimal: break
            default:
                relaxationFailures += 1
                unresolvedBound = min(unresolvedBound, node.inheritedBound); continue
            }
            solved += 1
            let lowerBound = solution.objectiveValue
            if let incumbent,
               lowerBound >= incumbent.objective - options.absoluteGapTolerance {
                prunedBound += 1; continue
            }
            let relaxationPoint = Array(solution.variableValues.prefix(problem.model.parameterCount))
            localSolves += 1
            if let candidate = try spatialLocalCandidate(
                problem, node.bounds, relaxationPoint, options),
               incumbent == nil || candidate.objective < incumbent!.objective {
                incumbent = candidate; incumbents += 1
            }
            guard let branch = spatialWidest(node.bounds, options.minimumWidth) else {
                unresolvedBound = min(unresolvedBound, lowerBound); continue
            }
            let lower = node.bounds[branch].lower!, upper = node.bounds[branch].upper!
            let midpoint = lower + 0.5 * (upper - lower)
            var left = node.bounds, right = node.bounds
            left[branch].upper = midpoint; right[branch].lower = midpoint
            nodes.append(.init(bounds: right, inheritedBound: lowerBound, depth: node.depth + 1))
            nodes.append(.init(bounds: left, inheritedBound: lowerBound, depth: node.depth + 1))
            let openBound = min(spatialGlobalBound(nodes, unresolvedBound), lowerBound)
            if observer?(.init(nodesExplored: explored, depth: node.depth,
                               relaxationBound: lowerBound,
                               incumbentObjective: incumbent?.objective,
                               openGlobalBound: openBound)) == false {
                cancelled = true; break
            }
            if let incumbent {
                let gap = max(0, incumbent.objective - openBound)
                let relative = gap / max(abs(incumbent.objective), 1)
                if gap <= options.absoluteGapTolerance
                    || relative <= options.relativeGapTolerance {
                    gapReached = true; break
                }
            }
        }

        let rawLower = spatialGlobalBound(nodes, unresolvedBound)
        let lowerBound = rawLower.isFinite ? rawLower : incumbent?.objective
        let gap = incumbent.flatMap { value in lowerBound.map { max(0, value.objective - $0) } }
        let relative = incumbent.flatMap { value in gap.map { $0 / max(abs(value.objective), 1) } }
        let termination: SpatialTermination
        if cancelled { termination = .cancelled
        } else if incumbent == nil && relaxationFailures > 0 {
            termination = .relaxationFailure
        } else if incumbent == nil && nodes.isEmpty && !unresolvedBound.isFinite {
            termination = .infeasible
        } else if gapReached { termination = .globalGap
        } else if !nodes.isEmpty { termination = .nodeLimit
        } else if unresolvedBound.isFinite { termination = .spatialResolution
        } else { termination = .searchExhausted }
        let certified = incumbent != nil
            && (termination == .globalGap || termination == .searchExhausted)
            && (gap.map { $0 <= options.absoluteGapTolerance } ?? false
                || relative.map { $0 <= options.relativeGapTolerance } ?? false)
        return .init(point: incumbent?.point ?? [], objective: incumbent?.objective ?? .nan,
                     globalLowerBound: lowerBound, absoluteGap: gap, relativeGap: relative,
                     nodesExplored: explored, relaxationsSolved: solved,
                     nodesPrunedByBound: prunedBound,
                     nodesPrunedInfeasible: prunedInfeasible,
                     nodesPrunedByPropagation: prunedPropagation,
                     propagationPasses: propagationPasses,
                     boundsTightened: boundsTightened, localSolves: localSolves,
                     incumbentsFound: incumbents, maximumDepth: maximumDepth,
                     globalOptimalityCertified: certified, termination: termination)
    }
}

private struct SpatialNode {
    var bounds: [ParameterBound]; var inheritedBound: Double; var depth: Int
}
private struct SpatialIncumbent { var point: [Double]; var objective: Double }

func spatialCompileRelaxation(
    _ problem: SpatialBranchAndBoundProblem, _ bounds: [ParameterBound]
) throws -> FFIProblem {
    guard let objectiveExpression = problem.model.objective else {
        throw NonlinearOptimizationError.invalidConfiguration("missing spatial objective")
    }
    let expressions = [objectiveExpression] + problem.constraints.map(\.expression)
    let relaxations = try expressions.map { try $0.globalRelaxation(bounds: bounds) }
    guard relaxations.allSatisfy({ relaxation in
        relaxation.complete && relaxation.analysis.nodes.allSatisfy(\.interval.isFinite)
    }) else {
        throw NonlinearOptimizationError.invalidConfiguration(
            "spatial branch-and-bound requires complete finite graph relaxations")
    }
    let parameterCount = problem.model.parameterCount
    let variables = parameterCount + expressions.reduce(0) { $0 + $1.nodes.count }
    var objective = [Double](repeating: 0, count: variables)
    var variableBounds = bounds.map { FFIBound(lower: $0.lower, upper: $0.upper) }
    var rows: [[Double]] = [], rowBounds: [FFIBound] = []
    var offset = parameterCount
    for expressionIndex in expressions.indices {
        let expression = expressions[expressionIndex], relaxation = relaxations[expressionIndex]
        variableBounds += relaxation.analysis.nodes.map {
            FFIBound(lower: $0.interval.lower, upper: $0.interval.upper)
        }
        for (nodeIndex, node) in expression.nodes.enumerated() {
            if case .parameter(let parameter) = node {
                var row = [Double](repeating: 0, count: variables)
                row[offset + nodeIndex] = 1; row[parameter] = -1
                rows.append(row); rowBounds.append(.init(lower: 0, upper: 0))
            }
        }
        for source in relaxation.rows {
            var row = [Double](repeating: 0, count: variables)
            row.replaceSubrange(offset..<(offset + source.coefficients.count),
                                with: source.coefficients)
            rows.append(row); rowBounds.append(.init(lower: source.lower, upper: source.upper))
        }
        let output = offset + expression.output
        if expressionIndex == 0 { objective[output] = 1 }
        else {
            var row = [Double](repeating: 0, count: variables); row[output] = 1
            let bound = problem.constraints[expressionIndex - 1].bound
            rows.append(row); rowBounds.append(.init(lower: bound.lower, upper: bound.upper))
        }
        offset += expression.nodes.count
    }
    var rowPointers = [0], columns: [Int] = [], values: [Double] = []
    for row in rows {
        for (column, value) in row.enumerated() where value != 0 {
            columns.append(column); values.append(value)
        }
        rowPointers.append(values.count)
    }
    return FFIProblem(objective: objective, constraintRows: rows.count,
                      constraintCols: variables, constraintRowPointers: rowPointers,
                      constraintColumnIndices: columns, constraintValues: values,
                      rowBounds: rowBounds, varBounds: variableBounds)
}

private func spatialLocalCandidate(
    _ problem: SpatialBranchAndBoundProblem, _ bounds: [ParameterBound],
    _ start: [Double], _ options: SpatialBranchAndBoundOptions
) throws -> SpatialIncumbent? {
    guard let expression = problem.model.objective else { return nil }
    let model = try NonlinearModel.objective(
        parameterCount: problem.model.parameterCount, bounds: bounds, expression: expression)
    let point: [Double]
    if problem.constraints.isEmpty {
        let result = try LBFGSB.minimize(model: model, initial: start,
                                        options: options.localOptions)
        guard result.termination == .convergedGradient
                || result.termination == .convergedObjective
                || result.termination == .convergedStep else { return nil }
        point = result.point
    } else {
        let constrained = try ConstrainedNonlinearProblem(
            model: model, constraints: problem.constraints)
        let result = try SequentialQuadraticProgramming.minimize(
            problem: constrained, initial: start, options: options.sqpOptions)
        guard result.termination == .converged,
              result.maximumViolation <= options.feasibilityTolerance else { return nil }
        point = result.point
    }
    let value = try model.evaluateObjective(parameters: point).value
    let feasible = try problem.constraints.allSatisfy { constraint in
        let evaluated = try constraint.expression.evaluate(parameters: point).value
        return (constraint.bound.lower.map { evaluated >= $0 - options.feasibilityTolerance } ?? true)
            && (constraint.bound.upper.map { evaluated <= $0 + options.feasibilityTolerance } ?? true)
    }
    return feasible ? .init(point: point, objective: value) : nil
}

private func spatialWidest(_ bounds: [ParameterBound], _ minimumWidth: Double) -> Int? {
    bounds.enumerated().compactMap { index, bound -> (Int, Double)? in
        guard let lower = bound.lower, let upper = bound.upper,
              upper - lower > minimumWidth else { return nil }
        return (index, upper - lower)
    }.max { $0.1 < $1.1 }?.0
}

private func spatialGlobalBound(_ nodes: [SpatialNode], _ unresolved: Double) -> Double {
    nodes.reduce(unresolved) { min($0, $1.inheritedBound) }
}

private func spatialValidate(_ options: SpatialBranchAndBoundOptions) throws {
    guard options.maxNodes > 0, options.simplexIterations > 0,
          options.propagationPasses > 0,
          options.propagationTolerance.isFinite, options.propagationTolerance >= 0,
          options.minimumWidth.isFinite, options.minimumWidth > 0,
          options.absoluteGapTolerance.isFinite, options.absoluteGapTolerance >= 0,
          options.relativeGapTolerance.isFinite, options.relativeGapTolerance >= 0,
          options.feasibilityTolerance.isFinite, options.feasibilityTolerance > 0 else {
        throw NonlinearOptimizationError.invalidConfiguration(
            "invalid spatial branch-and-bound options")
    }
}
