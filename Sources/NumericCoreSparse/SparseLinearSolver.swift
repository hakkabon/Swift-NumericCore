import NCBindings
import NumericCore

public enum SparsePreconditioner: Sendable, Hashable {
    case none, jacobi, ilu0, incompleteCholesky

    fileprivate var ffi: FFILinearPreconditioner {
        switch self {
        case .none: return .none
        case .jacobi: return .jacobi
        case .ilu0: return .ilu0
        case .incompleteCholesky: return .incompleteCholesky
        }
    }
}

public enum SparseIterativeMethod: Sendable, Hashable {
    case conjugateGradient
    case biCGSTAB
    case gmres(restart: Int)
}

public struct SparseIterativeOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var tolerance: Double
    public var initialSolution: [Double]?
    public var preconditioner: SparsePreconditioner

    public init(maxIterations: Int = 1_000, tolerance: Double = 1e-8,
                initialSolution: [Double]? = nil,
                preconditioner: SparsePreconditioner = .jacobi) {
        self.maxIterations = maxIterations; self.tolerance = tolerance
        self.initialSolution = initialSolution; self.preconditioner = preconditioner
    }
}

public enum SparseIterativeTermination: Sendable, Hashable {
    case converged, iterationLimit, breakdown
}

public struct SparseIterativeResult: Sendable, Hashable {
    public let solution: [Double]
    public let iterations: Int
    public let residualNorm: Double
    public let relativeResidual: Double
    public let termination: SparseIterativeTermination
    public var converged: Bool { termination == .converged }

    fileprivate init(_ result: FFILinearSolveResult) {
        solution = result.solution; iterations = result.iterations
        residualNorm = result.residualNorm; relativeResidual = result.relativeResidual
        switch result.termination {
        case .converged: termination = .converged
        case .iterationLimit: termination = .iterationLimit
        case .breakdown: termination = .breakdown
        }
    }
}

public struct SparseDirectResult: Sendable, Hashable {
    public let solution: [Double]
    public let residualNorm: Double
    public let relativeResidual: Double
    /// Stored entries in the computed factor or combined LU factors.
    public let factorNonZeroCount: Int

    fileprivate init(_ result: FFISparseDirectResult) {
        solution = result.solution; residualNorm = result.residualNorm
        relativeResidual = result.relativeResidual
        factorNonZeroCount = result.factorNonzeros
    }
}

/// Sparse direct and iterative linear system solvers backed by Rust-NumericCore.
/// Direct LU uses partial pivoting; Cholesky validates symmetry and positive
/// definiteness. Iterative methods report non-convergence without hiding it.
public enum SparseLinearSolver {
    public static func solveLU(
        matrix: SparseMatrix<Double>, rhs: [Double], dropTolerance: Double = 0
    ) throws -> SparseDirectResult {
        do {
            return SparseDirectResult(try FFIKernels.solveSparseLU(
                matrix: ffiMatrix(matrix), rhs: rhs, dropTolerance: dropTolerance))
        } catch let error as FFIError { throw error.sparseLinearError }
    }

    public static func solveCholesky(
        matrix: SparseMatrix<Double>, rhs: [Double], dropTolerance: Double = 0
    ) throws -> SparseDirectResult {
        do {
            return SparseDirectResult(try FFIKernels.solveSparseCholesky(
                matrix: ffiMatrix(matrix), rhs: rhs, dropTolerance: dropTolerance))
        } catch let error as FFIError { throw error.sparseLinearError }
    }

    public static func solve(
        matrix: SparseMatrix<Double>, rhs: [Double], method: SparseIterativeMethod,
        options: SparseIterativeOptions = .init()
    ) throws -> SparseIterativeResult {
        let ffiOptions = FFILinearSolveOptions(
            maxIterations: options.maxIterations, tolerance: options.tolerance,
            initialSolution: options.initialSolution,
            preconditioner: options.preconditioner.ffi)
        do {
            let result: FFILinearSolveResult
            switch method {
            case .conjugateGradient:
                result = try FFIKernels.solveSparseConjugateGradient(
                    matrix: ffiMatrix(matrix), rhs: rhs, options: ffiOptions)
            case .biCGSTAB:
                result = try FFIKernels.solveSparseBiCGSTAB(
                    matrix: ffiMatrix(matrix), rhs: rhs, options: ffiOptions)
            case .gmres(let restart):
                result = try FFIKernels.solveSparseGMRES(
                    matrix: ffiMatrix(matrix), rhs: rhs, options: ffiOptions, restart: restart)
            }
            return SparseIterativeResult(result)
        } catch let error as FFIError { throw error.sparseLinearError }
    }

    private static func ffiMatrix(_ matrix: SparseMatrix<Double>) -> FFICSRMatrix {
        .init(rows: matrix.rows, cols: matrix.cols,
              rowPointers: matrix.csrRowPointers,
              columnIndices: matrix.csrColumnIndices,
              values: matrix.csrValues)
    }
}

private extension FFIError {
    var sparseLinearError: NCError {
        switch self {
        case .dimensionMismatch(let message): return .dimensionMismatch(message)
        case .solverError(let message), .unknown(let message):
            return .unsupportedOperation(message)
        }
    }
}
