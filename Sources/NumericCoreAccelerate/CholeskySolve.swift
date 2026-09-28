import Accelerate
import NumericCore

/// Cholesky-based solve for symmetric positive-definite (SPD) systems —
/// the fast path requested for `Swift-DataLens`'s local-likelihood
/// calculations, where the normal-equations matrix `XᵀWX` is SPD by
/// construction. Roughly 2x fewer flops than the general QR path in
/// `QRSolve.swift` for a system where SPD-ness is already known to
/// hold, since Cholesky needs no pivoting/orthogonalization work.
///
/// Wraps `dpotrf_` (Cholesky factorization `A = LLᵀ`) and `dpotrs_`
/// (solve using the factored form) — the same classic Fortran-derived
/// LAPACK interface `QRSolve.swift` uses, and the same unverified-marshaling
/// caveat applies here (see that file's header comment) — build
/// `CholeskySolveTests.swift` before trusting this.
///
/// **This does not check symmetry.** LAPACK's `dpotrf_` only reads one
/// triangle of `A` (upper, per `uplo = "U"` below) and assumes the other
/// is its mirror — it will silently produce a wrong answer for a
/// non-symmetric input rather than erroring. Callers are responsible for
/// only calling this on matrices they know are symmetric (e.g. a
/// normal-equations matrix `XᵀWX`, which is symmetric by construction
/// regardless of `X`). If that guarantee doesn't hold for a given
/// caller, use `QRSolve.swift`'s general `solve(_:_:)` instead.
extension AccelerateBackend {
    /// Cholesky solve with explicit termination and backward residual
    /// diagnostics. As with `solveSPD`, symmetry remains a caller precondition.
    public static func solveSPDReport(
        _ a: Matrix<Double>,
        _ b: Vector<Double>,
        tolerance: NumericalTolerance = .scaleAware
    ) throws -> LinearSolveReport {
        guard tolerance.isValid else {
            throw LinearAlgebraError.invalidTolerance(
                "absolute and relative tolerances must be finite and non-negative"
            )
        }
        guard let solution = try solveSPD(a, b) else {
            return LinearSolveReport(solution: nil, termination: .notPositiveDefinite)
        }
        let diagnostics = residualDiagnostics(matrix: a, solution: solution, response: b)
        let threshold = tolerance.threshold(
            scale: 1, dimension: max(a.rows, a.cols)
        )
        let accepted = diagnostics.norm.isFinite && diagnostics.relative.isFinite
            && diagnostics.relative <= threshold
        return LinearSolveReport(
            solution: accepted ? solution : nil,
            termination: accepted ? .converged : .residualCheckFailed,
            residualNorm: diagnostics.norm,
            relativeResidual: diagnostics.relative,
            decisionThreshold: threshold
        )
    }

    /// Solve the SPD system `A x = b` via Cholesky factorization.
    ///
    /// Returns `nil` if `A` is not positive definite — LAPACK's
    /// `dpotrf_` detects this as a non-positive leading minor during
    /// factorization (reported via `info > 0`) rather than something
    /// checked against an explicit tolerance the way `QRSolve.swift`'s
    /// rank check is. A matrix that's positive definite but very close
    /// to singular may still report success with a poorly-conditioned
    /// result — this function only distinguishes definite/not-definite,
    /// not conditioning quality.
    public static func solveSPD(_ a: Matrix<Double>, _ b: Vector<Double>) throws -> Vector<Double>? {
        guard a.rows == a.cols else {
            throw LinearAlgebraError.dimensionMismatch(
                "solveSPD: matrix must be square, got \(a.shapeDescription)"
            )
        }
        guard a.rows == b.count else {
            throw LinearAlgebraError.dimensionMismatch(
                "solveSPD: matrix is \(a.shapeDescription), rhs has length \(b.count)"
            )
        }

        var n = Int32(a.rows)
        var lda = n
        var uplo: Int8 = Int8(UInt8(ascii: "U"))
        var info: Int32 = 0

        // dpotrf_ overwrites aData in place with the Cholesky factor U
        // (upper triangle; lower triangle of aData is left untouched
        // and must be ignored by anything reading it afterward).
        var aData = a.storage
        dpotrf_(&uplo, &n, &aData, &lda, &info)
        if info > 0 {
            // Leading minor of order `info` is not positive definite —
            // A is not SPD. This is the expected, documented `nil` case,
            // not an error.
            return nil
        }
        guard info == 0 else {
            throw LinearAlgebraError.lapackError(routine: "dpotrf", info: info)
        }

        // dpotrs_ solves A x = b using the factorization above, given
        // the same uplo. Overwrites bData in place with the solution.
        var bData = b.storage
        var nrhs: Int32 = 1
        var ldb = n
        dpotrs_(&uplo, &n, &nrhs, &aData, &lda, &bData, &ldb, &info)
        guard info == 0 else {
            throw LinearAlgebraError.lapackError(routine: "dpotrs", info: info)
        }

        return Vector(bData)
    }
}
