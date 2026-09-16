import Accelerate
import NumericCore

/// Singular Value Decomposition — `A = U Σ Vᵀ` — via LAPACK's `dgesvd_`.
/// The last of the decompositions ADR 0003 anticipated (QR, Cholesky,
/// LU, SVD), added once a concrete need showed up: rank-deficiency-robust
/// least squares, numerical rank, and pseudo-inverses all need it, and
/// none of QR/Cholesky/LU can substitute.
///
/// Computes the **thin** (economy) SVD — `jobu = jobvt = "S"` — not the
/// full one: for `A` of shape `m x n`, this gives `U` as `m x k`, `Vᵀ`
/// as `k x n`, with `k = min(m, n)`, rather than a full `m x m` `U`
/// whose extra columns span `A`'s left null space and are rarely what a
/// caller wants.
///
/// Same classic Fortran-derived LAPACK interface and the same
/// unverified-marshaling caveat as `QRSolve.swift`/`CholeskySolve.swift`/
/// `LUSolve.swift` — build `SVDTests.swift` before trusting this.
public struct SVDFactorization {
    /// `m x k` matrix of left singular vectors (orthonormal columns).
    public let u: Matrix<Double>
    /// Singular values, length `k`, in descending order (LAPACK's own
    /// convention — not re-sorted here).
    public let singularValues: Vector<Double>
    /// `k x n` matrix — `V` **transposed**, matching `dgesvd_`'s own
    /// output convention directly rather than transposing it back only
    /// for most callers to transpose it again.
    public let vt: Matrix<Double>
}

extension AccelerateBackend {
    public static func svd(_ a: Matrix<Double>) throws -> SVDFactorization {
        var m = Int32(a.rows)
        var n = Int32(a.cols)
        let k = Int(min(a.rows, a.cols))
        var lda = m
        var ldu = m
        var ldvt = Int32(k)
        var info: Int32 = 0

        var aData = a.storage
        var s = [Double](repeating: 0, count: k)
        var u = [Double](repeating: 0, count: a.rows * k)
        var vt = [Double](repeating: 0, count: k * a.cols)
        var jobu: Int8 = Int8(UInt8(ascii: "S"))
        var jobvt: Int8 = Int8(UInt8(ascii: "S"))

        var lwork: Int32 = -1
        var workQuery = [Double](repeating: 0, count: 1)
        dgesvd_(&jobu, &jobvt, &m, &n, &aData, &lda, &s, &u, &ldu, &vt, &ldvt, &workQuery, &lwork, &info)
        guard info == 0 else {
            throw LinearAlgebraError.lapackError(routine: "dgesvd (workspace query)", info: info)
        }
        lwork = Int32(workQuery[0])
        var work = [Double](repeating: 0, count: max(Int(lwork), 1))
        dgesvd_(&jobu, &jobvt, &m, &n, &aData, &lda, &s, &u, &ldu, &vt, &ldvt, &work, &lwork, &info)
        // info > 0 here means the underlying bidiagonal QR iteration
        // didn't converge — a genuine numerical failure, unlike
        // QR/Cholesky/LU's info > 0 (which just means "singular" /
        // "not SPD", an expected, `nil`-worthy outcome). SVD has no
        // comparable expected-failure mode, so this always throws
        // rather than returning an Optional.
        guard info == 0 else {
            throw LinearAlgebraError.lapackError(routine: "dgesvd", info: info)
        }

        return SVDFactorization(
            u: try Matrix(rows: a.rows, cols: k, storage: u),
            singularValues: Vector(s),
            vt: try Matrix(rows: k, cols: a.cols, storage: vt)
        )
    }

    /// Moore-Penrose pseudo-inverse via SVD: `A⁺ = V Σ⁺ Uᵀ`, where
    /// `Σ⁺` inverts each singular value above `tolerance` and zeroes
    /// out the rest. This is the standard, numerically stable way to
    /// compute a pseudo-inverse — never invert `AᵀA` directly, which
    /// squares the condition number.
    ///
    /// Well-defined for any `m x n` matrix regardless of rank —
    /// unlike `solve`/`solveLU`, this never returns `nil`; a
    /// rank-deficient or non-square `A` just gets more of `Σ⁺`'s
    /// diagonal zeroed out.
    public static func pseudoInverse(_ a: Matrix<Double>, tolerance: Double = 1e-10) throws -> Matrix<Double> {
        let factorization = try svd(a)
        let k = factorization.singularValues.count

        // V is n x k, the transpose of the k x n `vt` LAPACK returned.
        var v = Matrix<Double>(rows: a.cols, cols: k, repeating: 0)
        for row in 0..<a.cols {
            for col in 0..<k {
                v[row, col] = factorization.vt[col, row]
            }
        }
        // Scale V's columns by 1/sigma_i (0 where sigma_i <= tolerance)
        // — this is exactly "V * Sigma-plus" without materializing a
        // separate diagonal matrix.
        for col in 0..<k {
            let sigma = factorization.singularValues[col]
            let factor = sigma > tolerance ? 1.0 / sigma : 0.0
            for row in 0..<a.cols {
                v[row, col] *= factor
            }
        }

        // U^T is k x m, the transpose of the m x k `u` LAPACK returned.
        var ut = Matrix<Double>(rows: k, cols: a.rows, repeating: 0)
        for row in 0..<k {
            for col in 0..<a.rows {
                ut[row, col] = factorization.u[col, row]
            }
        }

        return try v * ut
    }

    /// Numerical rank via SVD: the count of singular values strictly
    /// greater than `tolerance`. The standard, numerically meaningful
    /// notion of rank for a matrix that's only known up to floating-point
    /// precision — unlike an exact linear-algebraic rank, this is
    /// deliberately tolerance-dependent, matching how `solveLU`'s
    /// singularity check and `leastSquares`'s rank check are also
    /// tolerance-dependent rather than exact.
    public static func rank(_ a: Matrix<Double>, tolerance: Double = 1e-10) throws -> Int {
        let factorization = try svd(a)
        return factorization.singularValues.storage.filter { $0 > tolerance }.count
    }

    /// Least-squares via the pseudo-inverse: `x = A⁺ b`, the minimum-norm
    /// solution to `min ||Ax - b||₂`.
    ///
    /// Unlike `leastSquares(design:response:)` (QR-based, in
    /// `QRSolve.swift`), this **never returns `nil`** — a rank-deficient
    /// `design` still has a well-defined minimum-norm least-squares
    /// solution via the pseudo-inverse, it's just not unique among all
    /// solutions achieving the minimum residual (the pseudo-inverse
    /// picks the one with smallest `‖x‖₂`). Prefer the QR-based version
    /// when rank deficiency should be treated as a caller-visible
    /// failure; prefer this one when a best-effort answer is more useful
    /// than a `nil` (e.g. a poorly-conditioned local regression window
    /// that should still produce *some* fit rather than abort).
    public static func leastSquaresSVD(
        design a: Matrix<Double>,
        response b: Vector<Double>,
        tolerance: Double = 1e-10
    ) throws -> Vector<Double> {
        guard a.rows == b.count else {
            throw LinearAlgebraError.dimensionMismatch(
                "leastSquaresSVD: design matrix is \(a.shapeDescription), response has length \(b.count)"
            )
        }
        let pseudoInv = try pseudoInverse(a, tolerance: tolerance)
        let bMatrix = try Matrix<Double>(rows: b.count, cols: 1, storage: b.storage)
        let xMatrix = try pseudoInv * bMatrix
        return Vector(xMatrix.storage)
    }
}
