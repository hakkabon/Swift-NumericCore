import NCBindings
import NumericCore
import NumericCoreSparse

/// A sparse contribution from a strict ancestor's decisions to a node's rows.
public struct ScenarioLink: Sendable {
    public let ancestor: UInt64
    public let coefficients: SparseMatrix<Double>

    public init(ancestor: UInt64, coefficients: SparseMatrix<Double>) {
        self.ancestor = ancestor
        self.coefficients = coefficients
    }
}

public struct ScenarioNode: Sendable {
    public let id: String
    public let parent: UInt64?
    public let conditionalProbability: Double
    public let block: SparseLinearProblem
    public let links: [ScenarioLink]

    public init(id: String, parent: UInt64?, conditionalProbability: Double,
                block: SparseLinearProblem, links: [ScenarioLink] = []) {
        self.id = id
        self.parent = parent
        self.conditionalProbability = conditionalProbability
        self.block = block
        self.links = links
    }
}

/// One decision block per information node, with parents preceding children.
public struct ScenarioTree: Sendable {
    public let nodes: [ScenarioNode]

    public init(nodes: [ScenarioNode]) {
        self.nodes = nodes
    }

    public init(twoStage problem: BendersProblem) {
        nodes = [.init(id: "first-stage", parent: nil, conditionalProbability: 1,
                       block: problem.firstStage)] + problem.scenarios.enumerated().map { index, scenario in
            .init(id: "\(index + 1):\(scenario.id.name)", parent: 0,
                  conditionalProbability: scenario.probability, block: scenario.recourse,
                  links: [.init(ancestor: 0, coefficients: scenario.coupling)])
        }
    }
}

public enum ScenarioRisk: Sendable, Hashable {
    case expectedValue
    /// A convex combination of the mean and upper-tail CVaR of total path cost.
    case meanCvar(alpha: Double, weight: Double)
}

public struct ScenarioSolveOptions: Sendable, Hashable {
    public var maxNodes: UInt64
    public var lpIterationLimit: UInt64
    public var tolerance: Double

    public init(maxNodes: UInt64 = 10_000, lpIterationLimit: UInt64 = 10_000, tolerance: Double = 1e-8) {
        self.maxNodes = maxNodes
        self.lpIterationLimit = lpIterationLimit
        self.tolerance = tolerance
    }
}

public enum ScenarioTermination: Sendable, Hashable {
    case converged, infeasible, nodeLimit, lpIterationLimit, missingEvidence, unboundedRelaxation
}

public struct ScenarioCost: Sendable, Hashable {
    public let id: String
    public let probability: Double
    public let cost: Double
}

public struct ScenarioPolicy: Sendable, Hashable {
    /// One vector per node in the assembled tree, in node order.
    public let decisions: [[Double]]
    public let terminalCosts: [ScenarioCost]
    public let expectedCost: Double
    public let valueAtRisk: Double?
    public let conditionalValueAtRisk: Double?
    public let objective: Double
}

public struct ScenarioSolveResult: Sendable, Hashable {
    public let termination: ScenarioTermination
    public let policy: ScenarioPolicy?
    public let lowerBound: Double?
    public let nodes: UInt64
}

public struct ScenarioEvaluation: Sendable, Hashable {
    public let sampleCount: UInt64
    public let mean: Double
    public let standardError: Double
    /// Asymptotic normal interval for a fixed decision evaluated on independent draws.
    public let confidenceInterval95: ClosedRange<Double>
}

public struct ReducedScenario: Sendable, Hashable {
    public let index: UInt64
    public let probability: Double
}

public struct ScenarioReduction: Sendable, Hashable {
    public let retained: [ReducedScenario]
    public let assignment: [UInt64]
    public let weightedDistance: Double
}

public struct ProgressiveHedgingOptions: Sendable, Hashable {
    public var rho: Double
    /// Additional iterations to perform when resuming.
    public var maxIterations: UInt64
    public var tolerance: Double
    public var qpIterationLimit: UInt64
    public var scenarioThreads: UInt64

    public init(rho: Double = 1, maxIterations: UInt64 = 250, tolerance: Double = 1e-5,
                qpIterationLimit: UInt64 = 10_000, scenarioThreads: UInt64 = 1) {
        self.rho = rho
        self.maxIterations = maxIterations
        self.tolerance = tolerance
        self.qpIterationLimit = qpIterationLimit
        self.scenarioThreads = scenarioThreads
    }
}

public struct HedgingWarmStart: Sendable, Hashable, Codable {
    public let primal: [Double]
    public let rowDual: [Double]
    public let variableDual: [Double]
}

/// A versioned snapshot that can be encoded and used to resume the same model.
public struct HedgingCheckpoint: Sendable, Hashable, Codable {
    public let version: UInt32
    public let modelSignature: UInt64
    public let iterations: UInt64
    public let consensus: [Double]
    public let multipliers: [[Double]]
    public let warmStarts: [HedgingWarmStart]
}

public enum HedgingTermination: Sendable, Hashable {
    case converged, iterationLimit, subproblemFailure
}

public struct ProgressiveHedgingResult: Sendable, Hashable {
    public let termination: HedgingTermination
    public let checkpoint: HedgingCheckpoint?
    public let primalResidual: Double?
    public let dualResidual: Double?
    public let failedScenario: UInt64?
}

public enum StochasticOptimization {
    public static var isAvailable: Bool {
        NumericCoreAPI.supports("stochastic-optimization")
    }

    public static func solve(_ tree: ScenarioTree, risk: ScenarioRisk = .expectedValue,
                             options: ScenarioSolveOptions = .init()) throws -> ScenarioSolveResult {
        #if NUMERICCORE_STOCHASTIC_FFI
        let nodes = try tree.nodes.map { node in
            try FfiScenarioNode(id: node.id, parent: node.parent, conditionalProbability: node.conditionalProbability,
                                block: ffiLPProblem(node.block), links: node.links.map {
                try .init(ancestor: $0.ancestor, coefficients: ffiBendersCoupling($0.coefficients))
            })
        }
        return scenarioResult(try solveScenarioTree(nodes: nodes, risk: risk.ffi, options: options.ffi))
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }

    /// Reproducible IID draws with replacement from the supplied probabilities.
    public static func draw(weights: [Double], count: UInt64, seed: UInt64) throws -> [UInt64] {
        #if NUMERICCORE_STOCHASTIC_FFI
        try drawScenarioIndices(weights: weights, count: count, seed: seed)
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }

    /// Duplicate draws become empirical weights. Recourse blocks follow source order.
    public static func solveSampleAverage(_ problem: BendersProblem, indices: [UInt64],
                                          risk: ScenarioRisk = .expectedValue,
                                          options: ScenarioSolveOptions = .init()) throws -> ScenarioSolveResult {
        #if NUMERICCORE_STOCHASTIC_FFI
        return scenarioResult(try solveScenarioSample(
            firstStage: ffiLPProblem(problem.firstStage), scenarios: problem.scenarios.map(ffiBendersScenario),
            indices: indices, risk: risk.ffi, options: options.ffi))
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }

    public static func evaluate(_ problem: BendersProblem, decision: [Double], indices: [UInt64],
                                options: ScenarioSolveOptions = .init()) throws -> ScenarioEvaluation {
        #if NUMERICCORE_STOCHASTIC_FFI
        let result = try evaluateScenarioPolicy(firstStage: ffiLPProblem(problem.firstStage),
            scenarios: problem.scenarios.map(ffiBendersScenario), decision: decision,
            indices: indices, options: options.ffi)
        return .init(sampleCount: result.sampleCount, mean: result.mean, standardError: result.standardError,
                     confidenceInterval95: result.confidenceLower...result.confidenceUpper)
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }

    /// Select representative scenarios using probability-weighted Euclidean distance.
    public static func reduce(features: [[Double]], weights: [Double], keep: UInt64) throws -> ScenarioReduction {
        #if NUMERICCORE_STOCHASTIC_FFI
        let result = try reduceScenarioFeatures(features: features, weights: weights, keep: keep)
        return .init(retained: result.retained.map { .init(index: $0.index, probability: $0.probability) },
                     assignment: result.assignment, weightedDistance: result.weightedDistance)
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }

    /// Solve a continuous two-stage model with a residual-based stopping rule.
    public static func hedge(_ problem: BendersProblem, options: ProgressiveHedgingOptions = .init(),
                             checkpoint: HedgingCheckpoint? = nil) throws -> ProgressiveHedgingResult {
        #if NUMERICCORE_STOCHASTIC_FFI
        let result = try runProgressiveHedging(firstStage: ffiLPProblem(problem.firstStage),
            scenarios: problem.scenarios.map(ffiBendersScenario),
            options: .init(rho: options.rho, maxIterations: options.maxIterations, tolerance: options.tolerance,
                           qpIterationLimit: options.qpIterationLimit, scenarioThreads: options.scenarioThreads),
            checkpoint: checkpoint?.ffi)
        let termination: HedgingTermination
        switch result.termination {
        case .converged: termination = .converged
        case .iterationLimit: termination = .iterationLimit
        case .subproblemFailure: termination = .subproblemFailure
        }
        return .init(termination: termination, checkpoint: result.checkpoint.map {
            .init(version: $0.version, modelSignature: $0.modelSignature, iterations: $0.iterations,
                  consensus: $0.consensus, multipliers: $0.multipliers, warmStarts: $0.warmStarts.map {
                .init(primal: $0.primal, rowDual: $0.rowDual, variableDual: $0.variableDual)
            })
        }, primalResidual: result.primalResidual, dualResidual: result.dualResidual,
           failedScenario: result.failedScenario)
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }
}

#if NUMERICCORE_STOCHASTIC_FFI
private extension HedgingCheckpoint {
    var ffi: FfiHedgingCheckpoint {
        .init(version: version, modelSignature: modelSignature, iterations: iterations, consensus: consensus,
              multipliers: multipliers, warmStarts: warmStarts.map {
            .init(primal: $0.primal, rowDual: $0.rowDual, variableDual: $0.variableDual)
        })
    }
}

private extension ScenarioSolveOptions {
    var ffi: FfiScenarioOptions {
        .init(maxNodes: maxNodes, lpIterationLimit: lpIterationLimit, tolerance: tolerance)
    }
}

private extension ScenarioRisk {
    var ffi: FfiScenarioRisk {
        switch self {
        case .expectedValue: .expectedValue
        case let .meanCvar(alpha, weight): .meanCvar(alpha: alpha, weight: weight)
        }
    }
}

private func scenarioResult(_ result: FfiScenarioSolveResult) -> ScenarioSolveResult {
    let termination: ScenarioTermination
    switch result.termination {
    case .converged: termination = .converged
    case .infeasible: termination = .infeasible
    case .nodeLimit: termination = .nodeLimit
    case .lpIterationLimit: termination = .lpIterationLimit
    case .missingEvidence: termination = .missingEvidence
    case .unboundedRelaxation: termination = .unboundedRelaxation
    }
    return .init(termination: termination, policy: result.policy.map {
        .init(decisions: $0.decisions, terminalCosts: $0.terminalCosts.map {
            .init(id: $0.id, probability: $0.probability, cost: $0.cost)
        }, expectedCost: $0.expectedCost, valueAtRisk: $0.valueAtRisk,
           conditionalValueAtRisk: $0.conditionalValueAtRisk, objective: $0.objective)
    }, lowerBound: result.lowerBound, nodes: result.nodes)
}
#endif
