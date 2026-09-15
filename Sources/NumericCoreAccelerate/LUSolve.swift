import Accelerate
import NumericCore

/// LU-based solve for general (not necessarily symmetric) square
/// systems — the last of the three solve paths alongside `QRSolve.swift`
/// (general, rank-checked via QR) and `CholeskySolve.swift` (SPD-only,
/// fastest). LU with partial pivoting is the standard general-purpose
/// choice for a square system: roughly half the flops of QR (no
/// orthogonalization step), at the cost of not directly generalizing to
/// the overdetermined case the way QR's `leastSquares` does — for a
/// non-square system, use `QRSolve.swift` instead.
///
/// Wraps `dgetrf_` (LU factorization with partial pivoting,
/// `PA = LU`) and `dgetrs_` (solve using the factored form) — the same
/// classic Fortran-derived LAPACK interface `QRSolve.swift`/
/// `CholeskySolve.swift` use, and the same unverified-marshaling caveat
/// applies here (see `QRSolve.swift`'s header comment) — build
/// `LUSolveTests.swift` before trusting this.
extension AccelerateBackend {
    /// Solve the general square system `A x = b` via LU decomposition
    /// with partial pivoting.
    ///
    /// Returns `nil` if `A` is singular — LAPACK's `dgetrf_` detects
    /// this as a zero pivot during factorization (reported via
    /// `info > 0`), matching the `nil`-on-failure contract already
    /// established by `solve(_:_:)`/`solveSPD(_:_:)`. As with those,
    /// this only distinguishes singular/non-singular, not conditioning
    /// quality — a matrix that's technically non-singular but very
    /// close to it may still report success with a poorly-conditioned
    /// result.
    ///
    /// Prefer `solveSPD(_:_:)` instead when `A` is known
    /// symmetric-positive-definite (fewer flops, no pivoting needed),
    /// and `solve(_:_:)`/`leastSquares(design:response:)` when `A` may
    /// be non-square or when a QR-based rank check specifically (rather
    /// than LU's singularity check) is what's needed.
    public static func solveLU(_ a: Matrix<Double>, _ b: Vector<Double>) throws -> Vector<Double>? {
        guard a.rows == a.cols else {
            throw LinearAlgebraError.dimensionMismatch(
                "solveLU: matrix must be square, got \(a.shapeDescription)"
            )
        }
        guard a.rows == b.count else {
            throw LinearAlgebraError.dimensionMismatch(
                "solveLU: matrix is \(a.shapeDescription), rhs has length \(b.count)"
            )
        }

        var m = Int32(a.rows)
        var n = m
        var lda = m
        var info: Int32 = 0

        // dgetrf_ overwrites aData in place with L (unit lower
        // triangular, implicit unit diagonal) and U (upper triangular),
        // and fills ipiv with the pivot indices dgetrs_ needs to apply
        // the same row interchanges to b.
        var aData = a.storage
        var ipiv = [Int32](repeating: 0, count: Int(min(m, n)))
        dgetrf_(&m, &n, &aData, &lda, &ipiv, &info)
        if info > 0 {
            // U(info, info) is exactly zero — A is singular. Expected,
            // documented `nil` case, not an error.
            return nil
        }
        guard info == 0 else {
            throw LinearAlgebraError.lapackError(routine: "dgetrf", info: info)
        }

        // dgetrs_ solves A x = b (trans = "N") using the factorization
        // and pivots above. Overwrites bData in place with the solution.
        var trans: Int8 = Int8(UInt8(ascii: "N"))
        var bData = b.storage
        var nrhs: Int32 = 1
        var ldb = m
        dgetrs_(&trans, &n, &nrhs, &aData, &lda, &ipiv, &bData, &ldb, &info)
        guard info == 0 else {
            throw LinearAlgebraError.lapackError(routine: "dgetrs", info: info)
        }

        return Vector(bData)
    }

    /// The matrix inverse of a square, non-singular `A`, via the same
    /// LU factorization as `solveLU`, solving `A X = I` column by
    /// column. Returns `nil` under the same singularity condition as
    /// `solveLU`.
    ///
    /// Computing an explicit inverse is rarely the right tool — solving
    /// `A x = b` directly via `solveLU`/`solve` is both cheaper and more
    /// numerically stable than forming `A⁻¹` and multiplying. This
    /// exists for the cases that genuinely need the inverse itself
    /// (e.g. a covariance matrix from a local-likelihood fit), not as
    /// the default way to solve a linear system.
    public static func inverse(_ a: Matrix<Double>) throws -> Matrix<Double>? {
        guard a.rows == a.cols else {
            throw LinearAlgebraError.dimensionMismatch(
                "inverse: matrix must be square, got \(a.shapeDescription)"
            )
        }

        let n = a.rows
        var columns: [Double] = []
        columns.reserveCapacity(n * n)

        for col in 0..<n {
            var identityColumn = Vector<Double>(repeating: 0, count: n)
            identityColumn[col] = 1
            guard let solved = try solveLU(a, identityColumn) else {
                return nil
            }
            columns.append(contentsOf: solved.storage)
        }

        // Each `solved` column is length n; `columns` is already laid
        // out column-by-column, which is exactly Matrix's column-major
        // storage (ADR 0001) — no reordering needed.
        return try Matrix(rows: n, cols: n, storage: columns)
    }
}
