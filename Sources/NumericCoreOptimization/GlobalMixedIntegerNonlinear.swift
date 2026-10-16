import Foundation
import NCBindings

public enum GlobalMINLPTermination: Sendable, Hashable {
    case globalGap, searchExhausted, spatialResolution, nodeLimit, infeasible,
         relaxationFailure, cancelled
}

public struct GlobalMINLPOptions: Sendable, Hashable {
    public var maxNodes: Int
    public var minimumWidth: Double
    public var integerTolerance: Double
    public var feasibilityTolerance: Double
    public var absoluteGapTolerance: Double
    public var relativeGapTolerance: Double
    public var simplexIterations: Int
    public var propagationPasses: Int
    public var propagationTolerance: Double
    public var enableRoundingHeuristic: Bool
    public var enableIntegerEnvelopeCuts: Bool
    public var maximumIntegerEnvelopeCuts: Int
    public var localOptions: LBFGSOptions
    public var sqpOptions: SQPOptions
    public init(maxNodes: Int = 20_000, minimumWidth: Double = 1e-4,
                integerTolerance: Double = 1e-7, feasibilityTolerance: Double = 1e-7,
                absoluteGapTolerance: Double = 1e-6, relativeGapTolerance: Double = 1e-6,
                simplexIterations: Int = 10_000, propagationPasses: Int = 8,
                propagationTolerance: Double = 1e-10, enableRoundingHeuristic: Bool = true,
                enableIntegerEnvelopeCuts: Bool = true,
                maximumIntegerEnvelopeCuts: Int = 256,
                localOptions: LBFGSOptions = .init(), sqpOptions: SQPOptions = .init()) {
        self.maxNodes = maxNodes; self.minimumWidth = minimumWidth
        self.integerTolerance = integerTolerance; self.feasibilityTolerance = feasibilityTolerance
        self.absoluteGapTolerance = absoluteGapTolerance
        self.relativeGapTolerance = relativeGapTolerance
        self.simplexIterations = simplexIterations; self.propagationPasses = propagationPasses
        self.propagationTolerance = propagationTolerance
        self.enableRoundingHeuristic = enableRoundingHeuristic
        self.enableIntegerEnvelopeCuts = enableIntegerEnvelopeCuts
        self.maximumIntegerEnvelopeCuts = maximumIntegerEnvelopeCuts
        self.localOptions = localOptions; self.sqpOptions = sqpOptions
    }
}

public struct GlobalMINLPProblem: Sendable, Hashable {
    public let model: NonlinearModel
    public let constraints: [NonlinearConstraint]
    public let isInteger: [Bool]
    public init(model: NonlinearModel, constraints: [NonlinearConstraint] = [],
                isInteger: [Bool]) throws {
        self.model = model; self.constraints = constraints; self.isInteger = isInteger
        try validate()
    }
    public func validate() throws {
        guard isInteger.count == model.parameterCount, isInteger.contains(true) else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "global MINLP requires one integrality flag per parameter")
        }
        _ = try SpatialBranchAndBoundProblem(model: model, constraints: constraints)
    }
}

public struct GlobalMINLPResult: Sendable, Hashable {
    public let point: [Double]; public let objective: Double
    public let globalLowerBound: Double?; public let absoluteGap: Double?; public let relativeGap: Double?
    public let nodesExplored: Int; public let relaxationsSolved: Int
    public let nodesPrunedByBound: Int; public let nodesPrunedInfeasible: Int
    public let nodesPrunedByPropagation: Int; public let propagationPasses: Int
    public let boundsTightened: Int; public let integerBranches: Int; public let spatialBranches: Int
    public let localSolves: Int; public let heuristicAttempts: Int; public let heuristicSuccesses: Int
    public let incumbentsFound: Int; public let maximumDepth: Int
    public let integerEnvelopeCutsGenerated: Int
    public let globalOptimalityCertified: Bool; public let termination: GlobalMINLPTermination
}

public struct GlobalMINLPIteration: Sendable, Hashable {
    public let nodesExplored: Int; public let depth: Int; public let relaxationBound: Double
    public let incumbentObjective: Double?; public let openGlobalBound: Double
}

public enum GlobalMixedIntegerNonlinearSolver {
    public typealias Observer = (GlobalMINLPIteration) -> Bool
    public static func minimize(problem: GlobalMINLPProblem,
                                options: GlobalMINLPOptions = .init(),
                                observer: Observer? = nil) throws -> GlobalMINLPResult {
        try problem.validate(); try validate(options)
        let spatial = try SpatialBranchAndBoundProblem(model: problem.model,
                                                       constraints: problem.constraints)
        var nodes = [GlobalNode(bounds: problem.model.bounds, inherited: -.infinity, depth: 0)]
        var incumbent: GlobalIncumbent?, unresolved = Double.infinity
        var explored = 0, solved = 0, pruneBound = 0, pruneInfeasible = 0
        var prunePropagation = 0, passes = 0, tightened = 0
        var integerBranches = 0, spatialBranches = 0, localSolves = 0
        var heuristicAttempts = 0, heuristicSuccesses = 0, incumbents = 0, maximumDepth = 0
        var envelopeCuts = 0
        var failures = 0, cancelled = false, gapReached = false
        while !nodes.isEmpty && explored < options.maxNodes {
            let index = nodes.indices.min { nodes[$0].inherited < nodes[$1].inherited }!
            var node = nodes.remove(at: index); explored += 1
            maximumDepth = max(maximumDepth, node.depth)
            guard normalize(&node.bounds, problem.isInteger, options.integerTolerance) else {
                pruneInfeasible += 1; continue
            }
            let propagation = try propagateNonlinearBounds(
                model: problem.model, constraints: problem.constraints, bounds: node.bounds,
                objectiveCutoff: incumbent.map { $0.objective - options.absoluteGapTolerance },
                options: .init(maxPasses: options.propagationPasses,
                               tolerance: options.propagationTolerance))
            passes += propagation.passes; tightened += propagation.boundsTightened
            if propagation.infeasible { pruneInfeasible += 1; prunePropagation += 1; continue }
            node.bounds = propagation.bounds
            guard normalize(&node.bounds, problem.isInteger, options.integerTolerance) else {
                pruneInfeasible += 1; prunePropagation += 1; continue
            }
            var relaxationProblem = try spatialCompileRelaxation(spatial, node.bounds)
            if options.enableIntegerEnvelopeCuts {
                let strengthened = strengthenIntegerSquareEnvelopes(
                    problem, bounds: node.bounds, relaxation: relaxationProblem,
                    maximumCuts: options.maximumIntegerEnvelopeCuts)
                relaxationProblem = strengthened.problem
                envelopeCuts += strengthened.cuts
            }
            let solution = try FFIKernels.solveLPSimplex(
                relaxationProblem,
                options: .init(maxIterations: UInt64(options.simplexIterations),
                               tolerance: min(1e-9, max(1e-12, options.feasibilityTolerance)),
                               scaling: true))
            switch solution.status {
            case .infeasible: pruneInfeasible += 1; continue
            case .optimal: break
            default: failures += 1; unresolved = min(unresolved, node.inherited); continue
            }
            solved += 1; let lower = solution.objectiveValue
            if let incumbent, lower >= incumbent.objective - options.absoluteGapTolerance {
                pruneBound += 1; continue
            }
            let point = Array(solution.variableValues.prefix(problem.model.parameterCount))
            let fractional = fractionalInteger(problem, point, options.integerTolerance)
            if options.enableRoundingHeuristic || fractional == nil {
                heuristicAttempts += 1; localSolves += 1
                if let candidate = try roundedCandidate(problem, node.bounds, point, options),
                   incumbent == nil || candidate.objective < incumbent!.objective {
                    incumbent = candidate; incumbents += 1; heuristicSuccesses += 1
                }
            }
            if let incumbent, lower >= incumbent.objective - options.absoluteGapTolerance {
                pruneBound += 1; continue
            }
            if let branch = fractional {
                integerBranches += 1
                var left = node.bounds, right = node.bounds
                left[branch].upper = min(left[branch].upper!, floor(point[branch]))
                right[branch].lower = max(right[branch].lower!, ceil(point[branch]))
                append(&nodes, right, lower, node.depth + 1); append(&nodes, left, lower, node.depth + 1)
            } else if let branch = widest(node.bounds, problem.isInteger, options.minimumWidth) {
                spatialBranches += 1
                let lo = node.bounds[branch].lower!, hi = node.bounds[branch].upper!
                var left = node.bounds, right = node.bounds
                if problem.isInteger[branch] {
                    let cut = floor(lo + 0.5 * (hi - lo))
                    left[branch].upper = cut; right[branch].lower = cut + 1
                } else {
                    let cut = lo + 0.5 * (hi - lo)
                    left[branch].upper = cut; right[branch].lower = cut
                }
                append(&nodes, right, lower, node.depth + 1); append(&nodes, left, lower, node.depth + 1)
            } else { unresolved = min(unresolved, lower) }
            let open = min(globalBound(nodes, unresolved), lower)
            if observer?(.init(nodesExplored: explored, depth: node.depth,
                               relaxationBound: lower, incumbentObjective: incumbent?.objective,
                               openGlobalBound: open)) == false { cancelled = true; break }
            if let incumbent {
                let gap = max(0, incumbent.objective - open)
                if gap <= options.absoluteGapTolerance
                    || gap / max(abs(incumbent.objective), 1) <= options.relativeGapTolerance {
                    gapReached = true; break
                }
            }
        }
        let rawLower = globalBound(nodes, unresolved)
        let lower = rawLower.isFinite ? rawLower : incumbent?.objective
        let gap = incumbent.flatMap { value in lower.map { max(0, value.objective - $0) } }
        let relative = incumbent.flatMap { value in gap.map { $0 / max(abs(value.objective), 1) } }
        let termination: GlobalMINLPTermination
        if cancelled { termination = .cancelled }
        else if failures > 0 && nodes.isEmpty { termination = .relaxationFailure }
        else if incumbent == nil && nodes.isEmpty && !unresolved.isFinite { termination = .infeasible }
        else if gapReached { termination = .globalGap }
        else if !nodes.isEmpty { termination = .nodeLimit }
        else if unresolved.isFinite { termination = .spatialResolution }
        else { termination = .searchExhausted }
        let certified = failures == 0 && incumbent != nil
            && (termination == .globalGap || termination == .searchExhausted)
            && (gap.map { $0 <= options.absoluteGapTolerance } ?? false
                || relative.map { $0 <= options.relativeGapTolerance } ?? false)
        return .init(point: incumbent?.point ?? [], objective: incumbent?.objective ?? .nan,
                     globalLowerBound: lower, absoluteGap: gap, relativeGap: relative,
                     nodesExplored: explored, relaxationsSolved: solved,
                     nodesPrunedByBound: pruneBound, nodesPrunedInfeasible: pruneInfeasible,
                     nodesPrunedByPropagation: prunePropagation, propagationPasses: passes,
                     boundsTightened: tightened, integerBranches: integerBranches,
                     spatialBranches: spatialBranches, localSolves: localSolves,
                     heuristicAttempts: heuristicAttempts, heuristicSuccesses: heuristicSuccesses,
                     incumbentsFound: incumbents, maximumDepth: maximumDepth,
                     integerEnvelopeCutsGenerated: envelopeCuts,
                     globalOptimalityCertified: certified, termination: termination)
    }
}

private struct GlobalNode { var bounds: [ParameterBound]; var inherited: Double; var depth: Int }
private struct GlobalIncumbent { var point: [Double]; var objective: Double }
private func strengthenIntegerSquareEnvelopes(
    _ problem: GlobalMINLPProblem, bounds: [ParameterBound], relaxation: FFIProblem,
    maximumCuts: Int
) -> (problem: FFIProblem, cuts: Int) {
    guard maximumCuts > 0 else { return (relaxation, 0) }
    let expressions = [problem.model.objective!] + problem.constraints.map(\.expression)
    var rowPointers = relaxation.constraintRowPointers
    var columns = relaxation.constraintColumnIndices
    var values = relaxation.constraintValues
    var rowBounds = relaxation.rowBounds
    var offset = problem.model.parameterCount, cuts = 0
    expressionLoop: for expression in expressions {
        for (nodeIndex, node) in expression.nodes.enumerated() {
            guard case .pow(let operand, let exponent) = node, exponent == 2,
                  case .parameter(let parameter) = expression.nodes[operand],
                  problem.isInteger[parameter],
                  let lower = bounds[parameter].lower, let upper = bounds[parameter].upper else {
                continue
            }
            let first = ceil(lower), last = floor(upper)
            guard first < last else { continue }
            var k = first
            while k < last {
                if cuts == maximumCuts { break expressionLoop }
                let slope = 2*k + 1
                let intercept = -k*(k+1)
                guard slope.isFinite, intercept.isFinite else { break }
                columns.append(parameter); values.append(-slope)
                columns.append(offset + nodeIndex); values.append(1)
                rowPointers.append(values.count)
                rowBounds.append(.init(lower: intercept, upper: nil))
                cuts += 1
                k += 1
            }
        }
        offset += expression.nodes.count
    }
    return (FFIProblem(objective: relaxation.objective,
        constraintRows: relaxation.constraintRows + cuts,
        constraintCols: relaxation.constraintCols,
        constraintRowPointers: rowPointers, constraintColumnIndices: columns,
        constraintValues: values, rowBounds: rowBounds,
        varBounds: relaxation.varBounds, isInteger: relaxation.isInteger), cuts)
}
private func roundedCandidate(_ problem: GlobalMINLPProblem, _ bounds: [ParameterBound],
                              _ point: [Double], _ options: GlobalMINLPOptions) throws
    -> GlobalIncumbent? {
    var fixed = bounds, start = point
    for i in start.indices where problem.isInteger[i] {
        let value = start[i].rounded()
        guard value >= fixed[i].lower!, value <= fixed[i].upper! else { return nil }
        fixed[i] = .fixed(value); start[i] = value
    }
    let model = try NonlinearModel.objective(parameterCount: problem.model.parameterCount,
        bounds: fixed, expression: problem.model.objective!)
    if problem.constraints.isEmpty {
        let result = try LBFGSB.minimize(model: model, initial: start, options: options.localOptions)
        guard result.termination == .convergedGradient || result.termination == .convergedObjective
                || result.termination == .convergedStep else { return nil }
        return .init(point: result.point, objective: result.objective)
    }
    let constrained = try ConstrainedNonlinearProblem(model: model, constraints: problem.constraints)
    let result = try SequentialQuadraticProgramming.minimize(
        problem: constrained, initial: start, options: options.sqpOptions)
    guard result.termination == .converged,
          result.maximumViolation <= options.feasibilityTolerance else { return nil }
    return .init(point: result.point, objective: result.objective)
}
private func normalize(_ bounds: inout [ParameterBound], _ flags: [Bool], _ tolerance: Double) -> Bool {
    for i in bounds.indices {
        if flags[i] { bounds[i].lower = ceil(bounds[i].lower! - tolerance)
            bounds[i].upper = floor(bounds[i].upper! + tolerance) }
        if bounds[i].lower! > bounds[i].upper! { return false }
    }; return true
}
private func fractionalInteger(_ problem: GlobalMINLPProblem, _ point: [Double], _ tolerance: Double) -> Int? {
    point.indices.filter { problem.isInteger[$0] && abs(point[$0]-point[$0].rounded()) > tolerance }
        .max { abs(point[$0]-point[$0].rounded()) < abs(point[$1]-point[$1].rounded()) }
}
private func widest(_ bounds: [ParameterBound], _ flags: [Bool], _ minimum: Double) -> Int? {
    bounds.indices.filter { bounds[$0].upper! - bounds[$0].lower! > (flags[$0] ? 0.5 : minimum) }
        .max { bounds[$0].upper! - bounds[$0].lower! < bounds[$1].upper! - bounds[$1].lower! }
}
private func append(_ nodes: inout [GlobalNode], _ bounds: [ParameterBound], _ inherited: Double, _ depth: Int) {
    if bounds.allSatisfy({ $0.lower! <= $0.upper! }) { nodes.append(.init(bounds: bounds, inherited: inherited, depth: depth)) }
}
private func globalBound(_ nodes: [GlobalNode], _ unresolved: Double) -> Double {
    nodes.reduce(unresolved) { min($0, $1.inherited) }
}
private func validate(_ o: GlobalMINLPOptions) throws {
    guard o.maxNodes > 0, o.simplexIterations > 0, o.propagationPasses > 0,
          o.maximumIntegerEnvelopeCuts >= 0,
          [o.minimumWidth, o.integerTolerance, o.feasibilityTolerance,
           o.absoluteGapTolerance, o.relativeGapTolerance,
           o.propagationTolerance].allSatisfy(\.isFinite),
          o.minimumWidth > 0, o.integerTolerance >= 0,
          o.feasibilityTolerance > 0, o.absoluteGapTolerance >= 0,
          o.relativeGapTolerance >= 0, o.propagationTolerance >= 0 else {
        throw NonlinearOptimizationError.invalidConfiguration("invalid global MINLP options")
    }
}
