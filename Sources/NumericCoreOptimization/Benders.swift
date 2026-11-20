import NCBindings
import NumericCore
import NumericCoreSparse

/// Recourse constraints are l ≤ W y + T x ≤ u. The recourse problem holds W
/// and its unshifted row bounds. The coupling matrix is T.
public struct BendersScenario: Sendable {
    public let id: LPSubproblemID
    public let probability: Double
    public let recourse: SparseLinearProblem
    public let coupling: SparseMatrix<Double>

    public init(id: LPSubproblemID, probability: Double, recourse: SparseLinearProblem,
                coupling: SparseMatrix<Double>) {
        self.id = id
        self.probability = probability
        self.recourse = recourse
        self.coupling = coupling
    }
}

public struct BendersProblem: Sendable {
    public let firstStage: SparseLinearProblem
    public let scenarios: [BendersScenario]

    public init(firstStage: SparseLinearProblem, scenarios: [BendersScenario]) {
        self.firstStage = firstStage
        self.scenarios = scenarios
    }

    public init(firstStage: SparseLinearProblem, recourse: SparseLinearProblem,
                coupling: SparseMatrix<Double>) {
        self.init(firstStage: firstStage, scenarios: [
            .init(id: .init(name: "recourse"), probability: 1, recourse: recourse, coupling: coupling),
        ])
    }
}

public enum BendersCutStrategy: Sendable, Hashable {
    case single, multi
}

public struct BendersOptions: Sendable, Hashable {
    public var cutStrategy: BendersCutStrategy
    public var maxIterations: UInt64
    public var lpIterationLimit: UInt64
    public var simplexTolerance: Double
    public var evidenceTolerance: Double
    public var absoluteGapTolerance: Double
    public var relativeGapTolerance: Double
    public var scenarioThreads: UInt64
    public var maximumInactiveRounds: UInt64?
    public var trustRegionRadius: Double?

    public init(cutStrategy: BendersCutStrategy = .multi, maxIterations: UInt64 = 100,
                lpIterationLimit: UInt64 = 10_000, simplexTolerance: Double = 1e-9,
                evidenceTolerance: Double = 1e-8, absoluteGapTolerance: Double = 1e-7,
                relativeGapTolerance: Double = 1e-7, scenarioThreads: UInt64 = 1,
                maximumInactiveRounds: UInt64? = nil, trustRegionRadius: Double? = nil) {
        self.cutStrategy = cutStrategy
        self.maxIterations = maxIterations
        self.lpIterationLimit = lpIterationLimit
        self.simplexTolerance = simplexTolerance
        self.evidenceTolerance = evidenceTolerance
        self.absoluteGapTolerance = absoluteGapTolerance
        self.relativeGapTolerance = relativeGapTolerance
        self.scenarioThreads = scenarioThreads
        self.maximumInactiveRounds = maximumInactiveRounds
        self.trustRegionRadius = trustRegionRadius
    }
}

public enum BendersTermination: Sendable, Hashable {
    case converged, infeasible, iterationLimit, lpIterationLimit, missingEvidence
    case recourseBoundUnavailable, masterUnbounded, stalled
}

public struct BendersRecourseSolution: Sendable, Hashable {
    public let id: LPSubproblemID
    public let point: [Double]
    public let objective: Double
}

public struct BendersIncumbent: Sendable, Hashable {
    public let firstStage: [Double]
    public let recourse: [BendersRecourseSolution]
    public let objective: Double
}

public struct BendersIteration: Sendable, Hashable {
    public let iteration: UInt64
    public let lowerBound: Double
    public let upperBound: Double?
    public let feasibilityCuts: UInt64
    public let optimalityCuts: UInt64
    public let cutsPruned: UInt64
    public let usedTrustRegion: Bool
    public let warmSubproblems: UInt64
}

public struct BendersResult: Sendable, Hashable {
    public let termination: BendersTermination
    public let incumbent: BendersIncumbent?
    public let lowerBound: Double?
    public let upperBound: Double?
    public let absoluteGap: Double?
    public let relativeGap: Double?
    public let history: [BendersIteration]
    public let blockingScenario: LPSubproblemID?
}

/// Classical Benders and L-shaped decomposition for continuous, two-stage LPs.
public enum BendersSolver {
    public static var isAvailable: Bool {
        #if NUMERICCORE_BENDERS_FFI
        true
        #else
        false
        #endif
    }

    public static func solve(_ problem: BendersProblem, options: BendersOptions = .init()) throws -> BendersResult {
        #if NUMERICCORE_BENDERS_FFI
        let result = try solveBendersDecomposition(
            firstStage: ffiLPProblem(problem.firstStage),
            scenarios: problem.scenarios.map { scenario in
                try FfiBendersScenario(
                    id: .init(name: scenario.id.name, scenario: scenario.id.scenario),
                    probability: scenario.probability,
                    recourse: ffiLPProblem(scenario.recourse),
                    coupling: ffiBendersCoupling(scenario.coupling))
            },
            options: .init(
                cutStrategy: options.cutStrategy == .single ? .single : .multi,
                maxIterations: options.maxIterations, lpIterationLimit: options.lpIterationLimit,
                simplexTolerance: options.simplexTolerance, evidenceTolerance: options.evidenceTolerance,
                absoluteGapTolerance: options.absoluteGapTolerance, relativeGapTolerance: options.relativeGapTolerance,
                scenarioThreads: options.scenarioThreads, maximumInactiveRounds: options.maximumInactiveRounds,
                trustRegionRadius: options.trustRegionRadius))
        let termination: BendersTermination
        switch result.termination {
        case .converged: termination = .converged
        case .infeasible: termination = .infeasible
        case .iterationLimit: termination = .iterationLimit
        case .lpIterationLimit: termination = .lpIterationLimit
        case .missingEvidence: termination = .missingEvidence
        case .recourseBoundUnavailable: termination = .recourseBoundUnavailable
        case .masterUnbounded: termination = .masterUnbounded
        case .stalled: termination = .stalled
        }
        return .init(
            termination: termination,
            incumbent: result.incumbent.map { incumbent in
                .init(firstStage: incumbent.firstStage, recourse: incumbent.recourse.map { solution in
                    .init(id: .init(name: solution.id.name, scenario: solution.id.scenario),
                          point: solution.point, objective: solution.objective)
                }, objective: incumbent.objective)
            },
            lowerBound: result.lowerBound, upperBound: result.upperBound,
            absoluteGap: result.absoluteGap, relativeGap: result.relativeGap,
            history: result.history.map {
                .init(iteration: $0.iteration, lowerBound: $0.lowerBound, upperBound: $0.upperBound,
                      feasibilityCuts: $0.feasibilityCuts, optimalityCuts: $0.optimalityCuts,
                      cutsPruned: $0.cutsPruned, usedTrustRegion: $0.usedTrustRegion,
                      warmSubproblems: $0.warmSubproblems)
            },
            blockingScenario: result.blockingScenario.map { .init(name: $0.name, scenario: $0.scenario) })
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }
}

#if NUMERICCORE_BENDERS_FFI
private func ffiBendersCoupling(_ matrix: SparseMatrix<Double>) throws -> FfiCsrMatrixF64 {
    guard let rows = UInt32(exactly: matrix.rows), let columns = UInt32(exactly: matrix.cols),
          UInt32(exactly: matrix.nonZeroCount) != nil else {
        throw LPDecompositionError.indexOutsideFFIRange
    }
    return .init(rows: rows, cols: columns, rowPtr: matrix.csrRowPointers.map { UInt32($0) },
                 colIndices: matrix.csrColumnIndices.map { UInt32($0) }, values: matrix.csrValues)
}
#endif
