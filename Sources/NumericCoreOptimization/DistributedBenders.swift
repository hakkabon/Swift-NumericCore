import Foundation
import NCBindings
import NumericCore

public struct DistributedBendersOptions: Sendable, Hashable {
    public var maxRounds: UInt64
    public var lpIterationLimit: UInt64
    public var evidenceTolerance: Double
    public var absoluteGap: Double
    public var relativeGap: Double

    public init(maxRounds: UInt64 = 100, lpIterationLimit: UInt64 = 10_000,
                evidenceTolerance: Double = 1e-8, absoluteGap: Double = 1e-7, relativeGap: Double = 1e-7) {
        self.maxRounds = maxRounds
        self.lpIterationLimit = lpIterationLimit
        self.evidenceTolerance = evidenceTolerance
        self.absoluteGap = absoluteGap
        self.relativeGap = relativeGap
    }
}

public enum DistributedBendersClaim: Sendable, Hashable {
    case bounds, optimality, infeasibility
}

public enum DistributedBendersStatus: Sendable, Hashable {
    case awaitingReplies, converged, infeasible, roundLimit, masterUnresolved, stalled
}

public enum DistributedBendersReplyDisposition: Sendable, Hashable {
    case accepted, duplicate, retry
}

public enum DistributedBendersError: Error, Sendable, Equatable {
    case unsupportedFFI
    case solver(String)
}

public struct DistributedBendersJob: Sendable, Hashable {
    public let round: UInt64
    public let scenarioIndex: UInt64
    /// Pass this JSON unchanged to a worker. The worker returns one JSON reply.
    public let json: String
}

public struct DistributedBendersAudit: Sendable, Hashable {
    public let claim: DistributedBendersClaim
    public let lowerBound: Double?
    public let upperBound: Double?
    public let absoluteGap: Double?
    public let relativeGap: Double?
    public let incumbent: BendersIncumbent?
    public let verifiedRounds: UInt64
    public let verifiedSubproblems: UInt64
    public let cuts: UInt64
}

public struct DistributedBendersProgress: Sendable, Hashable {
    public let status: DistributedBendersStatus
    public let audit: DistributedBendersAudit
}

/// Continuous two-stage Benders coordinator. Its private Rust handle serializes
/// submissions, progress queries and snapshots with a mutex.
public final class DistributedBendersCoordinator: @unchecked Sendable {
    #if NUMERICCORE_DISTRIBUTED_BENDERS_FFI
    private let handle: FfiDistributedBendersCoordinator
    #endif

    public static var isAvailable: Bool {
        NumericCoreAPI.supports("distributed-benders")
    }

    public init(problem: BendersProblem, runID: String = UUID().uuidString,
                options: DistributedBendersOptions = .init()) throws {
        #if NUMERICCORE_DISTRIBUTED_BENDERS_FFI
        handle = try distributedFFI {
            try startDistributedBenders(firstStage: ffiLPProblem(problem.firstStage),
                scenarios: problem.scenarios.map(ffiBendersScenario), runId: runID, options: options.ffi)
        }
        #else
        throw DistributedBendersError.unsupportedFFI
        #endif
    }

    public init(problem: BendersProblem, checkpoint: String,
                options: DistributedBendersOptions = .init()) throws {
        #if NUMERICCORE_DISTRIBUTED_BENDERS_FFI
        handle = try distributedFFI {
            try resumeDistributedBenders(firstStage: ffiLPProblem(problem.firstStage),
                scenarios: problem.scenarios.map(ffiBendersScenario), checkpoint: checkpoint, options: options.ffi)
        }
        #else
        throw DistributedBendersError.unsupportedFFI
        #endif
    }

    public func pendingJobs() throws -> [DistributedBendersJob] {
        #if NUMERICCORE_DISTRIBUTED_BENDERS_FFI
        try distributedFFI {
            try handle.pendingJobs().map { .init(round: $0.round, scenarioIndex: $0.scenario, json: $0.json) }
        }
        #else
        throw DistributedBendersError.unsupportedFFI
        #endif
    }

    @discardableResult
    public func submit(_ reply: String) throws -> DistributedBendersReplyDisposition {
        #if NUMERICCORE_DISTRIBUTED_BENDERS_FFI
        switch try distributedFFI({ try handle.submit(reply: reply) }) {
        case .accepted: .accepted
        case .duplicate: .duplicate
        case .retry: .retry
        }
        #else
        throw DistributedBendersError.unsupportedFFI
        #endif
    }

    public func progress() throws -> DistributedBendersProgress {
        #if NUMERICCORE_DISTRIBUTED_BENDERS_FFI
        let result = try distributedFFI { try handle.progress() }
        let status: DistributedBendersStatus
        switch result.status {
        case .awaitingReplies: status = .awaitingReplies
        case .converged: status = .converged
        case .infeasible: status = .infeasible
        case .roundLimit: status = .roundLimit
        case .masterUnresolved: status = .masterUnresolved
        case .stalled: status = .stalled
        }
        return .init(status: status, audit: fromDistributedAudit(result.audit))
        #else
        throw DistributedBendersError.unsupportedFFI
        #endif
    }

    public func exportCheckpoint() throws -> String {
        #if NUMERICCORE_DISTRIBUTED_BENDERS_FFI
        try distributedFFI { try handle.exportCheckpoint() }
        #else
        throw DistributedBendersError.unsupportedFFI
        #endif
    }

    public func exportProof() throws -> String {
        #if NUMERICCORE_DISTRIBUTED_BENDERS_FFI
        try distributedFFI { try handle.exportProof() }
        #else
        throw DistributedBendersError.unsupportedFFI
        #endif
    }

    /// Run the same stateless worker used by the Rust command-line executable.
    public static func executeJob(_ json: String) throws -> String {
        #if NUMERICCORE_DISTRIBUTED_BENDERS_FFI
        try distributedFFI { try executeDistributedBendersJob(job: json) }
        #else
        throw DistributedBendersError.unsupportedFFI
        #endif
    }

    /// Replay evidence against the supplied model and audit tolerances.
    public static func verify(problem: BendersProblem, proof: String,
                              options: DistributedBendersOptions = .init()) throws -> DistributedBendersAudit {
        #if NUMERICCORE_DISTRIBUTED_BENDERS_FFI
        try distributedFFI {
            fromDistributedAudit(try verifyDistributedBenders(firstStage: ffiLPProblem(problem.firstStage),
                scenarios: problem.scenarios.map(ffiBendersScenario), proof: proof, options: options.ffi))
        }
        #else
        throw DistributedBendersError.unsupportedFFI
        #endif
    }
}

#if NUMERICCORE_DISTRIBUTED_BENDERS_FFI
private extension DistributedBendersOptions {
    var ffi: FfiDistributedBendersOptions {
        .init(maxRounds: maxRounds, lpIterationLimit: lpIterationLimit,
              evidenceTolerance: evidenceTolerance, absoluteGap: absoluteGap, relativeGap: relativeGap)
    }
}

private func fromDistributedAudit(_ result: FfiDistributedBendersAudit) -> DistributedBendersAudit {
    let claim: DistributedBendersClaim
    switch result.claim {
    case .bounds: claim = .bounds
    case .optimality: claim = .optimality
    case .infeasibility: claim = .infeasibility
    }
    return .init(claim: claim, lowerBound: result.lowerBound, upperBound: result.upperBound,
                 absoluteGap: result.absoluteGap, relativeGap: result.relativeGap,
                 incumbent: result.incumbent.map(fromFFIBendersIncumbent), verifiedRounds: result.verifiedRounds,
                 verifiedSubproblems: result.verifiedSubproblems, cuts: result.cuts)
}

private func distributedFFI<T>(_ run: () throws -> T) throws -> T {
    do { return try run() }
    catch let error as FfiError {
        switch FFIKernels.translate(error) {
        case .dimensionMismatch(let message), .solverError(let message), .unknown(let message):
            throw DistributedBendersError.solver(message)
        }
    }
}
#endif
