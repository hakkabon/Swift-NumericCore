import NCBindings
import NumericCore

public enum SparseFactorizationMethod: Sendable, Hashable {
    case lu, cholesky, ldlt
}

public enum SparseSolveOrientation: Sendable, Hashable {
    case normal, transpose
}

public struct SparseFactorizationStatus: Sendable, Hashable {
    public let diagnostics: SparseFactorizationDiagnostics
    /// Available for LDLᵀ. Describes the numeric factor at its pivot threshold.
    public let inertia: SparseInertia?
}

/// Reusable symbolic analysis owned by the Rust solver. A single plan can
/// create several independent numeric workspaces with the same CSR pattern.
// The private UniFFI handle owns an immutable Rust analysis behind an Arc.
public final class SparseFactorizationPlan: @unchecked Sendable {
    public let size: Int
    public let ordering: SparseOrdering
    public let permutation: [Int]
    public let inversePermutation: [Int]
    public let originalNonZeroCount: Int
    public let estimatedFactorNonZeroCount: Int

    #if NUMERICCORE_SPARSE_WORKSPACE_FFI
    private let handle: FfiSparseFactorizationPlan
    #endif

    public static var isAvailable: Bool {
        NumericCoreAPI.supports("sparse-solver-workspaces")
    }

    public init(matrix: SparseMatrix<Double>, ordering: SparseOrdering = .minimumDegree) throws {
        #if NUMERICCORE_SPARSE_WORKSPACE_FFI
        let handle = try sparseFFI {
            try analyzeSparseFactorization(matrix: ffiMatrix(matrix), ordering: ordering.ffi)
        }
        let info = handle.info()
        self.handle = handle
        size = Int(info.size)
        self.ordering = ordering
        permutation = info.permutation.map(Int.init)
        inversePermutation = info.inversePermutation.map(Int.init)
        originalNonZeroCount = Int(info.originalNonzeros)
        estimatedFactorNonZeroCount = Int(info.estimatedFactorNonzeros)
        #else
        throw NCError.unsupportedOperation("The linked NumericCoreFFI does not provide sparse solver workspaces")
        #endif
    }

    public func factor(matrix: SparseMatrix<Double>, method: SparseFactorizationMethod,
                       options: SparseNumericOptions = .init()) throws -> SparseFactorizationWorkspace {
        #if NUMERICCORE_SPARSE_WORKSPACE_FFI
        guard let steps = UInt64(exactly: options.refinementSteps) else {
            throw NCError.unsupportedOperation("Refinement steps must be non-negative")
        }
        return try sparseFFI {
            let factor = try handle.factor(matrix: ffiMatrix(matrix), method: method.ffi, options: .init(
                pivotTolerance: options.pivotTolerance, dropTolerance: options.dropTolerance,
                refinementSteps: steps, refinementTolerance: options.refinementTolerance))
            return SparseFactorizationWorkspace(plan: self, method: method, options: options, handle: factor)
        }
        #else
        throw unavailableWorkspace()
        #endif
    }
}

/// Persistent Rust factor. Each solve batch sees a single numerical factor
/// even when another caller is refactoring the workspace.
// The private UniFFI handle owns a Rust RwLock that protects the numeric factor.
public final class SparseFactorizationWorkspace: @unchecked Sendable {
    public let plan: SparseFactorizationPlan
    public let method: SparseFactorizationMethod
    public let options: SparseNumericOptions

    #if NUMERICCORE_SPARSE_WORKSPACE_FFI
    private let handle: FfiSparseFactorization

    fileprivate init(plan: SparseFactorizationPlan, method: SparseFactorizationMethod,
                     options: SparseNumericOptions, handle: FfiSparseFactorization) {
        self.plan = plan
        self.method = method
        self.options = options
        self.handle = handle
    }
    #else
    private init(plan: SparseFactorizationPlan, method: SparseFactorizationMethod, options: SparseNumericOptions) {
        self.plan = plan
        self.method = method
        self.options = options
    }
    #endif

    /// A rejected pattern or failed numerical factorization preserves the previous factor.
    public func refactor(with matrix: SparseMatrix<Double>) throws {
        #if NUMERICCORE_SPARSE_WORKSPACE_FFI
        try sparseFFI { try handle.refactor(matrix: ffiMatrix(matrix)) }
        #else
        throw unavailableWorkspace()
        #endif
    }

    /// Supply only the updated values, in the original matrix's CSR storage order.
    public func refactor(values: [Double]) throws {
        #if NUMERICCORE_SPARSE_WORKSPACE_FFI
        try sparseFFI { try handle.refactorValues(values: values) }
        #else
        throw unavailableWorkspace()
        #endif
    }

    public func status() throws -> SparseFactorizationStatus {
        #if NUMERICCORE_SPARSE_WORKSPACE_FFI
        try sparseFFI {
            let status = try handle.status()
            return .init(diagnostics: diagnostics(status.diagnostics), inertia: status.inertia.map {
                .init(positive: Int($0.positive), negative: Int($0.negative), zero: Int($0.zero))
            })
        }
        #else
        throw unavailableWorkspace()
        #endif
    }

    public func solve(_ rhs: [Double], orientation: SparseSolveOrientation = .normal) throws -> [Double] {
        try solve([rhs], orientation: orientation)[0]
    }

    public func solve(_ rightHandSides: [[Double]],
                      orientation: SparseSolveOrientation = .normal) throws -> [[Double]] {
        #if NUMERICCORE_SPARSE_WORKSPACE_FFI
        try sparseFFI { try handle.solveBatch(rhs: rightHandSides, transpose: orientation == .transpose) }
        #else
        throw unavailableWorkspace()
        #endif
    }

    public func solveRefined(_ rhs: [Double],
                             orientation: SparseSolveOrientation = .normal) throws -> SparseRefinedResult {
        try solveRefined([rhs], orientation: orientation)[0]
    }

    public func solveRefined(_ rightHandSides: [[Double]],
                             orientation: SparseSolveOrientation = .normal) throws -> [SparseRefinedResult] {
        #if NUMERICCORE_SPARSE_WORKSPACE_FFI
        try sparseFFI {
            try handle.solveBatchRefined(rhs: rightHandSides, transpose: orientation == .transpose).map {
                .init(solution: $0.solution, residualNorm: $0.residualNorm, relativeResidual: $0.relativeResidual,
                      backwardError: $0.backwardError, refinementSteps: Int($0.refinementSteps),
                      diagnostics: diagnostics($0.diagnostics))
            }
        }
        #else
        throw unavailableWorkspace()
        #endif
    }
}

#if NUMERICCORE_SPARSE_WORKSPACE_FFI
private func sparseFFI<T>(_ run: () throws -> T) throws -> T {
    do { return try run() }
    catch let error as FFIError { throw error.sparseLinearError }
    catch { throw FFIKernels.translate(error).sparseLinearError }
}

private func ffiMatrix(_ matrix: SparseMatrix<Double>) throws -> FfiCsrMatrixF64 {
    try FFIKernels.makeFfiCSRMatrix(SparseLinearSolver.ffiMatrix(matrix))
}

private extension SparseOrdering {
    var ffi: FfiSparseOrdering {
        switch self {
        case .natural: .natural
        case .minimumDegree: .minimumDegree
        }
    }
}

private extension SparseFactorizationMethod {
    var ffi: FfiSparseFactorMethod {
        switch self {
        case .lu: .lu
        case .cholesky: .cholesky
        case .ldlt: .ldlt
        }
    }
}

private func diagnostics(_ d: FfiSparseFactorDiagnostics) -> SparseFactorizationDiagnostics {
    .init(ordering: d.ordering == .natural ? .natural : .minimumDegree,
          originalNonZeroCount: Int(d.originalNonzeros), factorNonZeroCount: Int(d.factorNonzeros),
          estimatedFactorNonZeroCount: Int(d.estimatedFactorNonzeros), fillRatio: d.fillRatio,
          minimumAbsolutePivot: d.minimumAbsPivot, pivotGrowth: d.pivotGrowth, interchangeCount: Int(d.interchanges))
}
#else
private func unavailableWorkspace() -> NCError {
    .unsupportedOperation("The linked NumericCoreFFI does not provide sparse solver workspaces")
}
#endif
