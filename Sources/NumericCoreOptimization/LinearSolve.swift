import NCBindings

/// Selects a solver for a sparse minimization problem.
public enum OptimizationSolveConfiguration: Sendable, Hashable {
    case automatic
    case simplex(SimplexSolveOptions = .init())
    case interiorPoint(InteriorPointSolveOptions = .init())
    case branchAndBound(BranchAndBoundSolveOptions = .init())
}

public struct SimplexSolveOptions: Sendable, Hashable {
    public var maxIterations: UInt64
    public var tolerance: Double
    public var scaling: Bool
    public init(maxIterations: UInt64 = 10_000, tolerance: Double = 1e-9, scaling: Bool = true) {
        self.maxIterations = maxIterations
        self.tolerance = tolerance
        self.scaling = scaling
    }
}

public struct InteriorPointSolveOptions: Sendable, Hashable {
    public var maxIterations: UInt64
    public var tolerance: Double
    public var sigma: Double
    public var bigBound: Double
    public var stepFraction: Double
    public var scaling: Bool
    public init(maxIterations: UInt64 = 200, tolerance: Double = 1e-8,
                sigma: Double = 0.1, bigBound: Double = 1e12,
                stepFraction: Double = 0.995, scaling: Bool = true) {
        self.maxIterations = maxIterations
        self.tolerance = tolerance
        self.sigma = sigma
        self.bigBound = bigBound
        self.stepFraction = stepFraction
        self.scaling = scaling
    }
}

public struct BranchAndBoundSolveOptions: Sendable, Hashable {
    public var maxNodes: UInt64
    public var integerTolerance: Double
    public var scaling: Bool
    public var initialIncumbent: [Double]?
    public var absoluteGapTolerance: Double
    public var relativeGapTolerance: Double
    public var nodeSelection: MILPNodeSelection
    public var branchingStrategy: MILPBranchingStrategy
    /// Enables iterative implied-bound propagation over every linear row.
    public var boundPropagation: Bool
    /// Rounds integer variables and repairs remaining continuous variables by
    /// solving the resulting fixed-integer LP.
    public var roundingHeuristic: Bool
    public init(maxNodes: UInt64 = 10_000, integerTolerance: Double = 1e-6,
                scaling: Bool = true, initialIncumbent: [Double]? = nil,
                absoluteGapTolerance: Double = 0, relativeGapTolerance: Double = 0,
                nodeSelection: MILPNodeSelection = .bestBound,
                branchingStrategy: MILPBranchingStrategy = .pseudoCost,
                boundPropagation: Bool = true, roundingHeuristic: Bool = true) {
        self.maxNodes = maxNodes
        self.integerTolerance = integerTolerance
        self.scaling = scaling
        self.initialIncumbent = initialIncumbent
        self.absoluteGapTolerance = absoluteGapTolerance
        self.relativeGapTolerance = relativeGapTolerance
        self.nodeSelection = nodeSelection
        self.branchingStrategy = branchingStrategy
        self.boundPropagation = boundPropagation
        self.roundingHeuristic = roundingHeuristic
    }
}

public enum MILPNodeSelection: Sendable, Hashable { case depthFirst, bestBound }
public enum MILPBranchingStrategy: Sendable, Hashable { case mostFractional, pseudoCost }
public enum MILPTermination: Sendable, Hashable {
    case exhausted, gapSatisfied, nodeLimit, relaxationLimit, unbounded, continuousRelaxation
}

public enum LPSolveStatus: Sendable, Hashable {
    case optimal
    case infeasible
    case unbounded
    case iterationLimit
}

public struct MILPSearchReport: Sendable, Hashable {
    public let nodesExplored: UInt64
    /// Best bound in minimization coordinates.
    public let bestBound: Double?
    public let absoluteGap: Double?
    public let relativeGap: Double?
    public let nodesPrunedInfeasible: UInt64
    public let nodesPrunedByBound: UInt64
    public let maximumDepth: UInt64
    public let relaxationsSolved: UInt64
    public let boundsTightened: UInt64
    public let incumbentsFound: UInt64
    public let heuristicAttempts: UInt64
    public let heuristicSuccesses: UInt64
    public let termination: MILPTermination
}

/// Result in the original numerical problem coordinates.
public struct LinearSolveResult: Sendable, Hashable {
    public let variableValues: [Double]
    public let objectiveValue: Double
    public let status: LPSolveStatus
    public let searchReport: MILPSearchReport?
}

public extension SparseLinearSolver {
    static func solve(_ problem: SparseLinearProblem,
                      configuration: OptimizationSolveConfiguration = .automatic) throws -> LinearSolveResult {
        try problem.validate()
        let result: FFISolution
        var milpReport: FFIMILPSolveReport?
        switch configuration {
        case .automatic:
            result = try problem.isInteger.contains(true)
                ? FFIKernels.solveMILP(problem.ffi)
                : FFIKernels.solveLPSimplex(problem.ffi)
        case .simplex(let options):
            result = try FFIKernels.solveLPSimplex(problem.ffi, options: .init(
                maxIterations: options.maxIterations, tolerance: options.tolerance,
                scaling: options.scaling
            ))
        case .interiorPoint(let options):
            result = try FFIKernels.solveLPInteriorPoint(problem.ffi, options: .init(
                maxIterations: options.maxIterations, tolerance: options.tolerance,
                sigma: options.sigma, bigBound: options.bigBound,
                stepFraction: options.stepFraction, scaling: options.scaling
            ))
        case .branchAndBound(let options):
            let report = try FFIKernels.solveMILP(problem.ffi, options: .init(
                maxNodes: options.maxNodes, integerTolerance: options.integerTolerance,
                scaling: options.scaling, initialIncumbent: options.initialIncumbent,
                absoluteGapTolerance: options.absoluteGapTolerance,
                relativeGapTolerance: options.relativeGapTolerance,
                nodeSelection: options.nodeSelection == .depthFirst ? .depthFirst : .bestBound,
                branchingStrategy: options.branchingStrategy == .mostFractional ? .mostFractional : .pseudoCost,
                boundPropagation: options.boundPropagation,
                roundingHeuristic: options.roundingHeuristic
            ))
            milpReport = report
            result = report.solution
        }

        let status: LPSolveStatus
        switch result.status {
        case .optimal: status = .optimal
        case .infeasible: status = .infeasible
        case .unbounded: status = .unbounded
        case .iterationLimit: status = .iterationLimit
        }

        return .init(variableValues: result.variableValues, objectiveValue: result.objectiveValue,
                     status: status, searchReport: milpReport.map { report in
                MILPSearchReport(
                    nodesExplored: report.nodesExplored,
                    bestBound: report.bestBound,
                    absoluteGap: report.absoluteGap,
                    relativeGap: report.relativeGap,
                    nodesPrunedInfeasible: report.nodesPrunedInfeasible,
                    nodesPrunedByBound: report.nodesPrunedByBound,
                    maximumDepth: report.maximumDepth,
                    relaxationsSolved: report.relaxationsSolved,
                    boundsTightened: report.boundsTightened,
                    incumbentsFound: report.incumbentsFound,
                    heuristicAttempts: report.heuristicAttempts,
                    heuristicSuccesses: report.heuristicSuccesses,
                    termination: mapTermination(report.termination)
                )
            })
    }

    private static func mapTermination(_ value: FFIBranchAndBoundTermination) -> MILPTermination {
        switch value {
        case .exhausted: return .exhausted
        case .gapSatisfied: return .gapSatisfied
        case .nodeLimit: return .nodeLimit
        case .relaxationLimit: return .relaxationLimit
        case .unbounded: return .unbounded
        case .continuousRelaxation: return .continuousRelaxation
        }
    }
}
