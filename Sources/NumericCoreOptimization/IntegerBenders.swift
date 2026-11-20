import NCBindings

public struct LogicBendersScenario: Sendable, Hashable {
    public let id: LPSubproblemID
    public let probability: Double
    /// Master columns in the order delivered to the oracle.
    public let binaryColumns: [Int]
    /// Caller-proven lower bound over every feasible binary assignment.
    public let objectiveLowerBound: Double

    public init(id: LPSubproblemID, probability: Double, binaryColumns: [Int],
                objectiveLowerBound: Double) {
        self.id = id
        self.probability = probability
        self.binaryColumns = binaryColumns
        self.objectiveLowerBound = objectiveLowerBound
    }
}

public enum IntegerBendersScenario: Sendable {
    case model(BendersScenario)
    case logic(LogicBendersScenario)
}

public struct IntegerBendersProblem: Sendable {
    public let firstStage: SparseLinearProblem
    public let scenarios: [IntegerBendersScenario]

    public init(firstStage: SparseLinearProblem, scenarios: [IntegerBendersScenario]) {
        self.firstStage = firstStage
        self.scenarios = scenarios
    }
}

/// A `nil` scope means the whole projection. A non-nil scope uses
/// zero-based positions within the supplied bit vector.
public enum LogicBendersEvaluation: Sendable, Hashable {
    /// The objective is attained at the trial. It also lower-bounds the
    /// recourse cost at every assignment that matches the validity bits.
    case optimal(objective: Double, point: [Double] = [], validity: [UInt32]? = nil)
    /// Every assignment matching the conflict bits must be infeasible.
    case infeasible(conflict: [UInt32]? = nil)
    case unresolved
}

public struct IntegerBendersOptions: Sendable, Hashable {
    public var maxMasterNodes: UInt64
    public var maxCandidateEvaluations: UInt64
    public var maxRecourseNodes: UInt64
    public var lpIterationLimit: UInt64
    public var simplexTolerance: Double
    public var evidenceTolerance: Double
    public var integralityTolerance: Double
    public var absoluteGapTolerance: Double
    public var relativeGapTolerance: Double

    public init(maxMasterNodes: UInt64 = 10_000, maxCandidateEvaluations: UInt64 = 1_000,
                maxRecourseNodes: UInt64 = 10_000, lpIterationLimit: UInt64 = 10_000,
                simplexTolerance: Double = 1e-9, evidenceTolerance: Double = 1e-8,
                integralityTolerance: Double = 1e-7, absoluteGapTolerance: Double = 1e-7,
                relativeGapTolerance: Double = 1e-7) {
        self.maxMasterNodes = maxMasterNodes
        self.maxCandidateEvaluations = maxCandidateEvaluations
        self.maxRecourseNodes = maxRecourseNodes
        self.lpIterationLimit = lpIterationLimit
        self.simplexTolerance = simplexTolerance
        self.evidenceTolerance = evidenceTolerance
        self.integralityTolerance = integralityTolerance
        self.absoluteGapTolerance = absoluteGapTolerance
        self.relativeGapTolerance = relativeGapTolerance
    }
}

public enum IntegerBendersTermination: Sendable, Hashable {
    case converged, infeasible, masterNodeLimit, candidateLimit, lpIterationLimit
    case recourseNodeLimit, oracleUnresolved, missingEvidence, recourseBoundUnavailable
    case masterUnbounded, stalled
}

public struct IntegerBendersResult: Sendable, Hashable {
    public let termination: IntegerBendersTermination
    public let incumbent: BendersIncumbent?
    public let lowerBound: Double?
    public let upperBound: Double?
    public let absoluteGap: Double?
    public let relativeGap: Double?
    public let masterNodes: UInt64
    public let candidateEvaluations: UInt64
    public let recourseEvaluations: UInt64
    public let assignmentCacheHits: UInt64
    public let feasibilityCuts: UInt64
    public let optimalityCuts: UInt64
    public let blockingScenario: LPSubproblemID?
    /// Bounds and cut claims rely on the supplied logic assertions when true.
    public let usesLogicOracle: Bool
}

public enum IntegerBendersSolver {
    public typealias Oracle = (LPSubproblemID, [Bool]) -> LogicBendersEvaluation

    public static var isAvailable: Bool {
        #if NUMERICCORE_INTEGER_BENDERS_FFI
        true
        #else
        false
        #endif
    }

    public static func solve(_ problem: BendersProblem,
                             options: IntegerBendersOptions = .init()) throws -> IntegerBendersResult {
        try solve(.init(firstStage: problem.firstStage, scenarios: problem.scenarios.map(IntegerBendersScenario.model)),
                  options: options, oracle: { _, _ in .unresolved })
    }

    /// Calls the logic oracle synchronously for integer candidates only.
    public static func solve(_ problem: IntegerBendersProblem, options: IntegerBendersOptions = .init(),
                             oracle: @escaping Oracle) throws -> IntegerBendersResult {
        #if NUMERICCORE_INTEGER_BENDERS_FFI
        let result = try solveIntegerBendersDecomposition(
            firstStage: ffiLPProblem(problem.firstStage),
            scenarios: problem.scenarios.map { scenario in
                switch scenario {
                case .model(let model):
                    return try .model(scenario: ffiBendersScenario(model))
                case .logic(let logic):
                    let columns = try logic.binaryColumns.map { index in
                        guard let converted = UInt32(exactly: index) else {
                            throw LPDecompositionError.indexOutsideFFIRange
                        }
                        return converted
                    }
                    return .logic(scenario: .init(
                        id: .init(name: logic.id.name, scenario: logic.id.scenario),
                        probability: logic.probability, binaryColumns: columns,
                        objectiveLowerBound: logic.objectiveLowerBound))
                }
            },
            options: .init(
                maxMasterNodes: options.maxMasterNodes, maxCandidateEvaluations: options.maxCandidateEvaluations,
                maxRecourseNodes: options.maxRecourseNodes, lpIterationLimit: options.lpIterationLimit,
                simplexTolerance: options.simplexTolerance, evidenceTolerance: options.evidenceTolerance,
                integralityTolerance: options.integralityTolerance, absoluteGapTolerance: options.absoluteGapTolerance,
                relativeGapTolerance: options.relativeGapTolerance),
            oracle: IntegerBendersOracleBridge(oracle))
        let termination: IntegerBendersTermination
        switch result.termination {
        case .converged: termination = .converged
        case .infeasible: termination = .infeasible
        case .masterNodeLimit: termination = .masterNodeLimit
        case .candidateLimit: termination = .candidateLimit
        case .lpIterationLimit: termination = .lpIterationLimit
        case .recourseNodeLimit: termination = .recourseNodeLimit
        case .oracleUnresolved: termination = .oracleUnresolved
        case .missingEvidence: termination = .missingEvidence
        case .recourseBoundUnavailable: termination = .recourseBoundUnavailable
        case .masterUnbounded: termination = .masterUnbounded
        case .stalled: termination = .stalled
        }
        return .init(
            termination: termination, incumbent: result.incumbent.map(fromFFIBendersIncumbent),
            lowerBound: result.lowerBound, upperBound: result.upperBound,
            absoluteGap: result.absoluteGap, relativeGap: result.relativeGap,
            masterNodes: result.masterNodes, candidateEvaluations: result.candidateEvaluations,
            recourseEvaluations: result.recourseEvaluations, assignmentCacheHits: result.assignmentCacheHits,
            feasibilityCuts: result.feasibilityCuts, optimalityCuts: result.optimalityCuts,
            blockingScenario: result.blockingScenario.map { .init(name: $0.name, scenario: $0.scenario) },
            usesLogicOracle: result.usesLogicOracle)
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }
}

#if NUMERICCORE_INTEGER_BENDERS_FFI
private final class IntegerBendersOracleBridge: FfiLogicBendersOracle {
    private let oracle: IntegerBendersSolver.Oracle

    init(_ oracle: @escaping IntegerBendersSolver.Oracle) {
        self.oracle = oracle
    }

    func evaluate(id: FfiLpSubproblemId, bits: [Bool]) -> FfiLogicBendersEvaluation {
        switch oracle(.init(name: id.name, scenario: id.scenario), bits) {
        case .optimal(let objective, let point, let validity):
            return .optimal(objective: objective, point: point, validity: validity)
        case .infeasible(let conflict): return .infeasible(conflict: conflict)
        case .unresolved: return .unresolved
        }
    }
}
#endif
