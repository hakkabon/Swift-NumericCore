import NCBindings
import NumericCore

/// Graph parameters are the selected master columns followed by the private variables.
public struct NonlinearRecourseBlock: Sendable, Hashable {
    public let id: String
    public let sharedColumns: [UInt64]
    public let localBounds: [ParameterBound]
    public let weight: Double
    public let objective: NonlinearExpression
    public let constraints: [NonlinearConstraint]

    public init(id: String, sharedColumns: [UInt64], localBounds: [ParameterBound],
                weight: Double = 1, objective: NonlinearExpression,
                constraints: [NonlinearConstraint] = []) {
        self.id = id
        self.sharedColumns = sharedColumns
        self.localBounds = localBounds
        self.weight = weight
        self.objective = objective
        self.constraints = constraints
    }
}

public struct NonlinearDecompositionProblem: Sendable {
    public let master: SparseLinearProblem
    public let blocks: [NonlinearRecourseBlock]

    public init(master: SparseLinearProblem, blocks: [NonlinearRecourseBlock]) {
        self.master = master
        self.blocks = blocks
    }
}

public struct NonlinearDecompositionOptions: Sendable, Hashable {
    public var maxMasterSolves: UInt64
    public var maxBlockSolves: UInt64
    public var lpIterationLimit: UInt64
    public var feasibilityTolerance: Double
    public var absoluteGap: Double
    public var relativeGap: Double

    public init(maxMasterSolves: UInt64 = 1_000, maxBlockSolves: UInt64 = 100,
                lpIterationLimit: UInt64 = 10_000, feasibilityTolerance: Double = 1e-8,
                absoluteGap: Double = 1e-6, relativeGap: Double = 1e-6) {
        self.maxMasterSolves = maxMasterSolves
        self.maxBlockSolves = maxBlockSolves
        self.lpIterationLimit = lpIterationLimit
        self.feasibilityTolerance = feasibilityTolerance
        self.absoluteGap = absoluteGap
        self.relativeGap = relativeGap
    }
}

public enum NonlinearDecompositionTermination: Sendable, Hashable {
    case converged, infeasible, masterLimit, recourseLimit, lpIterationLimit
    case missingEvidence, evaluationFailure, stalled
}

public struct NonlinearRecourseSolution: Sendable, Hashable {
    public let id: String
    public let localPoint: [Double]
    public let objective: Double
    public let maximumViolation: Double
}

public struct NonlinearDecompositionIncumbent: Sendable, Hashable {
    public let masterPoint: [Double]
    public let recourse: [NonlinearRecourseSolution]
    public let objective: Double
}

public struct NonlinearDecompositionResult: Sendable, Hashable {
    public let termination: NonlinearDecompositionTermination
    public let incumbent: NonlinearDecompositionIncumbent?
    public let lowerBound: Double?
    public let masterSolves: UInt64
    public let recourseSolves: UInt64
    public let feasibilityCuts: UInt64
    public let optimalityCuts: UInt64
    public let blockingBlock: String?
}

public enum NonlinearDecompositionSolver {
    public static var isAvailable: Bool {
        NumericCoreAPI.supports("nonlinear-decomposition")
    }

    /// Minimize linear master cost plus weighted, convex recourse costs.
    public static func solve(_ problem: NonlinearDecompositionProblem,
                             options: NonlinearDecompositionOptions = .init()) throws
        -> NonlinearDecompositionResult {
        #if NUMERICCORE_NONLINEAR_DECOMPOSITION_FFI
        let result = try solveNonlinearDecomposition(
            master: ffiLPProblem(problem.master), blocks: problem.blocks.map(ffiBlock),
            options: .init(maxMasterSolves: options.maxMasterSolves, maxBlockSolves: options.maxBlockSolves,
                           lpIterationLimit: options.lpIterationLimit, feasibilityTolerance: options.feasibilityTolerance,
                           absoluteGap: options.absoluteGap, relativeGap: options.relativeGap))
        let termination: NonlinearDecompositionTermination
        switch result.termination {
        case .converged: termination = .converged
        case .infeasible: termination = .infeasible
        case .masterLimit: termination = .masterLimit
        case .recourseLimit: termination = .recourseLimit
        case .lpIterationLimit: termination = .lpIterationLimit
        case .missingEvidence: termination = .missingEvidence
        case .evaluationFailure: termination = .evaluationFailure
        case .stalled: termination = .stalled
        }
        return .init(termination: termination, incumbent: result.incumbent.map {
            .init(masterPoint: $0.masterPoint, recourse: $0.recourse.map {
                .init(id: $0.id, localPoint: $0.localPoint, objective: $0.objective, maximumViolation: $0.maximumViolation)
            }, objective: $0.objective)
        }, lowerBound: result.lowerBound, masterSolves: result.masterSolves, recourseSolves: result.recourseSolves,
           feasibilityCuts: result.feasibilityCuts, optimalityCuts: result.optimalityCuts,
           blockingBlock: result.blockingBlock)
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }

    #if NUMERICCORE_NONLINEAR_DECOMPOSITION_FFI
    private static func ffiBlock(_ block: NonlinearRecourseBlock) throws -> FfiNonlinearRecourseBlock {
        let parameterCount = block.sharedColumns.count + block.localBounds.count
        func graph(_ expression: NonlinearExpression) throws -> FfiNonlinearExpression {
            guard UInt32(exactly: parameterCount) != nil, UInt32(exactly: expression.nodes.count) != nil else {
                throw LPDecompositionError.indexOutsideFFIRange
            }
            try expression.validate(parameterCount: parameterCount)
            return FFIKernels.makeFfiNonlinearExpression(NonlinearModelSolver.ffi(expression))
        }
        return try .init(id: block.id, sharedColumns: block.sharedColumns,
                         localBounds: block.localBounds.map { .init(lower: $0.lower, upper: $0.upper) },
                         weight: block.weight, objective: graph(block.objective), constraints: block.constraints.map {
            try .init(expression: graph($0.expression), bound: .init(lower: $0.bound.lower, upper: $0.bound.upper))
        })
    }
    #endif
}
