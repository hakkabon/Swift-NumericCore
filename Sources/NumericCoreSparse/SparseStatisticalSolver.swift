import NCBindings
import NumericCore

/// Result of a portable CSR weighted or penalized least-squares solve.
///
/// The objective is `weightedResidualSumOfSquares + penaltyContribution`.
/// Unlike the small-dense QR API, this is an iterative solve: inspect
/// `converged` before treating `coefficients` as a fitted model. A false
/// value is intentionally returned as diagnostic information rather than
/// hidden by a partial result or a dense fallback.
public struct SparseStatisticalLeastSquaresResult: Sendable, Hashable {
    public let coefficients: [Double]
    public let iterations: Int
    public let residualNorm: Double
    public let converged: Bool
    public let weightedResidualSumOfSquares: Double
    public let penaltyContribution: Double

    /// `Σᵢ wᵢ(yᵢ - xᵢᵀβ)² + λ‖Pβ‖²` at the reported iterate.
    public var objective: Double {
        weightedResidualSumOfSquares + penaltyContribution
    }

    fileprivate init(_ result: FFISparseStatisticalSolveResult) {
        coefficients = result.solution
        iterations = result.iterations
        residualNorm = result.residualNorm
        converged = result.converged
        weightedResidualSumOfSquares = result.weightedResidualSumOfSquares
        penaltyContribution = result.penaltyContribution
    }
}

/// Sparse, portable statistical solves backed by Rust-NumericCore's CSR CGLS
/// implementation.
///
/// Use this boundary for large sparse basis and penalty operators (not as a
/// replacement for `NumericCoreAccelerate.StatisticalSolver`'s rank-revealing
/// QR path on small dense problems). Both methods leave the design and penalty
/// matrices in CSR form and do not form normal equations.
public enum SparseStatisticalSolver {
    /// Solve `min Σᵢ wᵢ(yᵢ - xᵢᵀβ)²` over a CSR design matrix.
    ///
    /// A zero weight excludes an observation. The returned result may be
    /// unconverged when `maxIterations` is exhausted; callers must check
    /// `converged` before inference or prediction.
    public static func weightedLeastSquares(
        design: SparseMatrix<Double>,
        response: [Double],
        weights: [Double],
        maxIterations: Int = 1_000,
        tolerance: Double = 1e-8
    ) throws -> SparseStatisticalLeastSquaresResult {
        do {
            let result = try FFIKernels.solveSparseWeightedLeastSquares(
                design: ffiMatrix(design),
                response: response,
                weights: weights,
                maxIterations: maxIterations,
                tolerance: tolerance
            )
            return SparseStatisticalLeastSquaresResult(result)
        } catch let error as FFIError {
            throw error.asSparseNCError
        }
    }

    /// Solve `min Σᵢ wᵢ(yᵢ - xᵢᵀβ)² + λ‖Pβ‖²` over CSR design and penalty
    /// operators. `penalty` must have one column per design coefficient and
    /// `penaltyWeight` must be finite and strictly positive.
    public static func penalizedWeightedLeastSquares(
        design: SparseMatrix<Double>,
        response: [Double],
        weights: [Double],
        penalty: SparseMatrix<Double>,
        penaltyWeight: Double,
        maxIterations: Int = 1_000,
        tolerance: Double = 1e-8
    ) throws -> SparseStatisticalLeastSquaresResult {
        do {
            let result = try FFIKernels.solveSparsePenalizedWeightedLeastSquares(
                design: ffiMatrix(design),
                response: response,
                weights: weights,
                penalty: ffiMatrix(penalty),
                penaltyWeight: penaltyWeight,
                maxIterations: maxIterations,
                tolerance: tolerance
            )
            return SparseStatisticalLeastSquaresResult(result)
        } catch let error as FFIError {
            throw error.asSparseNCError
        }
    }

    private static func ffiMatrix(_ matrix: SparseMatrix<Double>) -> FFICSRMatrix {
        FFICSRMatrix(
            rows: matrix.rows,
            cols: matrix.cols,
            rowPointers: matrix.csrRowPointers,
            columnIndices: matrix.csrColumnIndices,
            values: matrix.csrValues
        )
    }
}

private extension FFIError {
    var asSparseNCError: NCError {
        switch self {
        case .dimensionMismatch(let message):
            return .dimensionMismatch(message)
        case .solverError(let message), .unknown(let message):
            return .unsupportedOperation(message)
        }
    }
}
