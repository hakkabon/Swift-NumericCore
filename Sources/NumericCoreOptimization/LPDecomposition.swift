import NCBindings

/// Only the new workspace API requires the Phase 61 Rust artifact.
public enum LPDecompositionError: Error, Equatable {
    case unsupportedFFI
    case indexOutsideFFIRange
}

public enum LPBasisStatus: Sendable, Hashable {
    case basic, atLower, atUpper, free
}

public struct LPBasis: Sendable, Hashable {
    public let variables: [LPBasisStatus]
    public let rows: [LPBasisStatus]

    public init(variables: [LPBasisStatus], rows: [LPBasisStatus]) {
        self.variables = variables
        self.rows = rows
    }
}

public struct LPSubproblemID: Sendable, Hashable {
    public let name: String
    public let scenario: String?

    public init(name: String, scenario: String? = nil) {
        self.name = name
        self.scenario = scenario
    }
}

public struct LPDualSolution: Sendable, Hashable {
    /// Positive multipliers select lower bounds in minimization coordinates.
    public let rowMultipliers: [Double]
    public let reducedCosts: [Double]
    public let objectiveBound: Double
    public let absoluteGap: Double
}

public struct LPFarkasCertificate: Sendable, Hashable {
    public let rowMultipliers: [Double]
    public let variableMultipliers: [Double]
    public let contradictionMargin: Double
}

public struct LPUnboundedRay: Sendable, Hashable {
    public let direction: [Double]
    public let objectiveSlope: Double
}

public struct LPReoptimizationReport: Sendable, Hashable {
    public let variableValues: [Double]
    public let objectiveValue: Double
    public let status: LPSolveStatus
    public let basis: LPBasis
    public let dual: LPDualSolution?
    public let infeasibility: LPFarkasCertificate?
    public let unboundedRay: LPUnboundedRay?
    public let subproblem: LPSubproblemID?
    public let usedWarmStart: Bool
    public let iterations: UInt64
    public let pivots: UInt64
    public let maximumBasicReducedCost: Double?
}

public struct LPIndexedValue: Sendable, Hashable {
    public let index: Int
    public let value: Double

    public init(index: Int, value: Double) {
        self.index = index
        self.value = value
    }
}

public struct LPBoundEdit: Sendable, Hashable {
    public let index: Int
    public let bound: ParameterBound

    public init(index: Int, bound: ParameterBound) {
        self.index = index
        self.bound = bound
    }
}

public struct LPAppendedRow: Sendable, Hashable {
    public let entries: [LPIndexedValue]
    public let bound: ParameterBound

    public init(entries: [LPIndexedValue], bound: ParameterBound) {
        self.entries = entries
        self.bound = bound
    }
}

public struct LPAppendedColumn: Sendable, Hashable {
    public let entries: [LPIndexedValue]
    public let bound: ParameterBound
    public let objective: Double

    public init(entries: [LPIndexedValue], bound: ParameterBound, objective: Double) {
        self.entries = entries
        self.bound = bound
        self.objective = objective
    }
}

/// Edits are evaluated atomically. New rows refer to existing columns.
/// New columns may refer to existing rows and rows appended in this update.
public struct LPModelUpdate: Sendable, Hashable {
    public var objective: [LPIndexedValue]
    public var variableBounds: [LPBoundEdit]
    public var rowBounds: [LPBoundEdit]
    public var appendRows: [LPAppendedRow]
    public var appendColumns: [LPAppendedColumn]

    public init(objective: [LPIndexedValue] = [], variableBounds: [LPBoundEdit] = [],
                rowBounds: [LPBoundEdit] = [], appendRows: [LPAppendedRow] = [],
                appendColumns: [LPAppendedColumn] = []) {
        self.objective = objective
        self.variableBounds = variableBounds
        self.rowBounds = rowBounds
        self.appendRows = appendRows
        self.appendColumns = appendColumns
    }
}

public struct LPReoptimizationOptions: Sendable, Hashable {
    public var maxIterations: UInt64
    public var tolerance: Double
    public var evidenceTolerance: Double

    public init(maxIterations: UInt64 = 10_000, tolerance: Double = 1e-9,
                evidenceTolerance: Double = 1e-8) {
        self.maxIterations = maxIterations
        self.tolerance = tolerance
        self.evidenceTolerance = evidenceTolerance
    }
}

/// A continuous LP with retained simplex state. Each call is serialized by
/// the Rust handle. Use separate workspaces for independent subproblems.
public final class LPReoptimizationWorkspace: @unchecked Sendable {
    #if NUMERICCORE_LP_DECOMPOSITION_FFI
    private let handle: FfiLpWorkspace
    #endif

    public static var isAvailable: Bool {
        #if NUMERICCORE_LP_DECOMPOSITION_FFI
        true
        #else
        false
        #endif
    }

    public init(problem: SparseLinearProblem, subproblem: LPSubproblemID? = nil) throws {
        #if NUMERICCORE_LP_DECOMPOSITION_FFI
        handle = try FfiLpWorkspace(
            problem: ffiLPProblem(problem),
            subproblem: subproblem.map { FfiLpSubproblemId(name: $0.name, scenario: $0.scenario) })
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }

    public func installBasis(_ basis: LPBasis) throws {
        #if NUMERICCORE_LP_DECOMPOSITION_FFI
        try handle.installBasis(basis: .init(
            variables: basis.variables.map(\.ffi), rows: basis.rows.map(\.ffi)))
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }

    public func update(_ edits: LPModelUpdate) throws {
        #if NUMERICCORE_LP_DECOMPOSITION_FFI
        try handle.update(update: .init(
            objective: edits.objective.map { try $0.ffi() },
            variableBounds: edits.variableBounds.map { try $0.ffi() },
            rowBounds: edits.rowBounds.map { try $0.ffi() },
            appendRows: edits.appendRows.map { row in
                try .init(entries: row.entries.map { try $0.ffi() }, bound: row.bound.ffi)
            },
            appendColumns: edits.appendColumns.map { column in
                try .init(entries: column.entries.map { try $0.ffi() }, bound: column.bound.ffi,
                          objective: column.objective)
            }))
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }

    public func solve(options: LPReoptimizationOptions = .init()) throws -> LPReoptimizationReport {
        #if NUMERICCORE_LP_DECOMPOSITION_FFI
        let result = try handle.solve(maxIterations: options.maxIterations, tolerance: options.tolerance,
                                      evidenceTolerance: options.evidenceTolerance)
        let status: LPSolveStatus
        switch result.solution.status {
        case .optimal: status = .optimal
        case .infeasible: status = .infeasible
        case .unbounded: status = .unbounded
        case .iterationLimit: status = .iterationLimit
        }
        return .init(
            variableValues: result.solution.variableValues, objectiveValue: result.solution.objectiveValue,
            status: status, basis: .init(variables: result.basis.variables.map(LPBasisStatus.init),
                                        rows: result.basis.rows.map(LPBasisStatus.init)),
            dual: result.dual.map(LPDualSolution.init),
            infeasibility: result.infeasibility.map(LPFarkasCertificate.init),
            unboundedRay: result.unboundedRay.map(LPUnboundedRay.init),
            subproblem: result.subproblem.map { .init(name: $0.name, scenario: $0.scenario) },
            usedWarmStart: result.usedWarmStart, iterations: result.iterations, pivots: result.pivots,
            maximumBasicReducedCost: result.maximumBasicReducedCost)
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }
}

/// Audits candidates against an input model without requiring solver state.
public enum LPDecompositionEvidence {
    public static func dual(problem: SparseLinearProblem, point: [Double],
                            rowMultipliers: [Double], tolerance: Double = 1e-8) throws -> LPDualSolution? {
        #if NUMERICCORE_LP_DECOMPOSITION_FFI
        return try verifyLpDualEvidence(problem: ffiLPProblem(problem), point: point,
                                       rowMultipliers: rowMultipliers, tolerance: tolerance)
            .map(LPDualSolution.init)
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }

    public static func farkas(problem: SparseLinearProblem, rowMultipliers: [Double],
                              tolerance: Double = 1e-8) throws -> LPFarkasCertificate? {
        #if NUMERICCORE_LP_DECOMPOSITION_FFI
        return try verifyLpFarkasEvidence(problem: ffiLPProblem(problem), rowMultipliers: rowMultipliers,
                                         tolerance: tolerance).map(LPFarkasCertificate.init)
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }

    public static func unboundedRay(problem: SparseLinearProblem, anchor: [Double], direction: [Double],
                                    tolerance: Double = 1e-8) throws -> LPUnboundedRay? {
        #if NUMERICCORE_LP_DECOMPOSITION_FFI
        return try verifyLpUnboundedEvidence(problem: ffiLPProblem(problem), anchor: anchor,
                                            direction: direction, tolerance: tolerance)
            .map(LPUnboundedRay.init)
        #else
        throw LPDecompositionError.unsupportedFFI
        #endif
    }
}

public extension PresolvedLinearProblem {
    /// Zero-extend removed rows and certify the lifted dual on the original LP.
    func liftLPDual(original: SparseLinearProblem, reducedPoint: [Double], reducedRowMultipliers: [Double],
                    tolerance: Double = 1e-8) throws -> LPDualSolution? {
        guard let rows = extendedRows(reducedRowMultipliers, count: original.rows) else { return nil }
        return try LPDecompositionEvidence.dual(problem: original, point: restorePoint(reducedPoint),
                                                rowMultipliers: rows, tolerance: tolerance)
    }

    func liftLPFarkas(original: SparseLinearProblem, reducedRowMultipliers: [Double],
                      tolerance: Double = 1e-8) throws -> LPFarkasCertificate? {
        guard let rows = extendedRows(reducedRowMultipliers, count: original.rows) else { return nil }
        return try LPDecompositionEvidence.farkas(problem: original, rowMultipliers: rows,
                                                  tolerance: tolerance)
    }

    func liftLPUnboundedRay(original: SparseLinearProblem, reducedPoint: [Double], reducedDirection: [Double],
                            tolerance: Double = 1e-8) throws -> LPUnboundedRay? {
        guard reducedDirection.count == activeVariables.count,
              activeVariables.allSatisfy({ (0..<original.columns).contains($0) }) else { return nil }
        var direction = [Double](repeating: 0, count: original.columns)
        for (index, value) in zip(activeVariables, reducedDirection) { direction[index] = value }
        return try LPDecompositionEvidence.unboundedRay(problem: original, anchor: restorePoint(reducedPoint),
                                                        direction: direction, tolerance: tolerance)
    }

    private func extendedRows(_ reduced: [Double], count: Int) -> [Double]? {
        guard reduced.count == keptRows.count,
              keptRows.allSatisfy({ (0..<count).contains($0) }) else { return nil }
        var rows = [Double](repeating: 0, count: count)
        for (index, value) in zip(keptRows, reduced) { rows[index] = value }
        return rows
    }
}

#if NUMERICCORE_LP_DECOMPOSITION_FFI
private func ffiLPProblem(_ problem: SparseLinearProblem) throws -> FfiProblem {
    try problem.validate()
    guard UInt32(exactly: problem.rows) != nil, UInt32(exactly: problem.columns) != nil,
          UInt32(exactly: problem.values.count) != nil else {
        throw LPDecompositionError.indexOutsideFFIRange
    }
    return FFIKernels.makeFfiProblem(problem.ffi)
}

private func ffiIndex(_ index: Int) throws -> UInt32 {
    guard let result = UInt32(exactly: index) else { throw LPDecompositionError.indexOutsideFFIRange }
    return result
}

private extension LPIndexedValue {
    func ffi() throws -> FfiLpEntry { try .init(index: ffiIndex(index), value: value) }
}

private extension LPBoundEdit {
    func ffi() throws -> FfiLpBoundEdit { try .init(index: ffiIndex(index), bound: bound.ffi) }
}

private extension ParameterBound {
    var ffi: FfiBound { .init(lower: lower, upper: upper) }
}

private extension LPBasisStatus {
    var ffi: FfiLpBasisStatus {
        switch self {
        case .basic: .basic
        case .atLower: .atLower
        case .atUpper: .atUpper
        case .free: .free
        }
    }

    init(_ status: FfiLpBasisStatus) {
        switch status {
        case .basic: self = .basic
        case .atLower: self = .atLower
        case .atUpper: self = .atUpper
        case .free: self = .free
        }
    }
}

private extension LPDualSolution {
    init(_ value: FfiLpDualSolution) {
        self.init(rowMultipliers: value.rowMultipliers, reducedCosts: value.reducedCosts,
                  objectiveBound: value.objectiveBound, absoluteGap: value.absoluteGap)
    }
}

private extension LPFarkasCertificate {
    init(_ value: FfiLpFarkasCertificate) {
        self.init(rowMultipliers: value.rowMultipliers, variableMultipliers: value.variableMultipliers,
                  contradictionMargin: value.contradictionMargin)
    }
}

private extension LPUnboundedRay {
    init(_ value: FfiLpUnboundedRay) {
        self.init(direction: value.direction, objectiveSlope: value.objectiveSlope)
    }
}
#endif
