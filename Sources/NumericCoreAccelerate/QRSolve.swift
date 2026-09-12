import Accelerate
import NumericCore

/// Errors from decomposition/solve operations.
///
/// Kept separate from `BackendError` (the `Backend` protocol's dispatch
/// error): decompositions aren't routed through `DispatchPolicy` yet —
/// per ADR 0003, `AccelerateBackend` is the *only* implementation, so
/// there's nothing to dispatch between. These are called as direct
/// static methods, not through `Dispatcher`.
public enum LinearAlgebraError: Error {
    case dimensionMismatch(String)
    case lapackError(routine: String, info: Int32)
}

/// QR-decomposition-based solving: `solve` (square systems) and
/// `leastSquares` (overdetermined systems), wrapping Accelerate's
/// LAPACK entry points directly (`dgeqrf_`/`dormqr_`/`dtrtrs_` — the
/// classic Fortran-derived interface Accelerate exposes to Swift/C, the
/// same one libraries like Surge call into).
///
/// This is deliberately QR-only, not a general decomposition module —
/// per the original scoping conversation, "QR + square solve is all
/// LOESS needs," and per ADR 0003's broader principle, this project
/// doesn't build decomposition support ahead of a concrete consumer.
/// `Swift-DataLens`'s `LinAlg.leastSquares(design:response:)` and
/// `Regression.solve(_:_:)` are that consumer — this file's two public
/// functions are written to be a near-direct drop-in for those two
/// signatures (see that project's integration notes in
/// `docs/design/datalens-integration.md`).
///
/// ## A caveat worth taking seriously
/// This file was written without access to a Swift compiler or a real
/// Accelerate/LAPACK header to check against — the exact parameter
/// marshaling for `dgeqrf_`/`dormqr_`/`dtrtrs_` (argument order, the
/// `__CLPK_integer`/`__CLPK_doublereal` typealiases, `UnsafeMutablePointer`
/// vs plain `&x` argument passing for single scalars) is written from
/// the well-established LAPACK Fortran calling convention and the
/// pattern used by other Accelerate-based Swift projects, but has not
/// been compiled or run. **Build and run `QRSolveTests.swift` before
/// trusting this file** — if the LAPACK symbol signatures Xcode
/// actually exposes differ in some detail, the fix is almost certainly
/// local to this file (adjusting pointer/type marshaling), not a
/// redesign of the public API below.
extension AccelerateBackend {
    /// Solve the square linear system `A x = b`.
    ///
    /// Returns `nil` if `A` is (numerically) rank-deficient — i.e. any
    /// diagonal entry of its QR factor `R` has magnitude at or below
    /// `pivotTolerance`. This matches the `nil`-on-rank-deficiency (or
    /// `nil`-on-small-pivot) contract already established by
    /// `Swift-DataLens`'s `Regression.solve(_:_:)`.
    public static func solve(
        _ a: Matrix<Double>,
        _ b: Vector<Double>,
        pivotTolerance: Double = 1e-12
    ) throws -> Vector<Double>? {
        guard a.rows == a.cols else {
            throw LinearAlgebraError.dimensionMismatch(
                "solve: matrix must be square, got \(a.shapeDescription)"
            )
        }
        return try leastSquares(design: a, response: b, rankTolerance: pivotTolerance)
    }

    /// Solve the (possibly overdetermined) least-squares problem
    /// `min ||A x - b||₂` via thin QR decomposition.
    ///
    /// `A` must have `rows >= cols` (a square system is the `rows ==
    /// cols` special case — `solve(_:_:)` above just calls through to
    /// this). Returns `nil` if `A` does not have full column rank.
    public static func leastSquares(
        design a: Matrix<Double>,
        response b: Vector<Double>,
        rankTolerance: Double = 1e-12
    ) throws -> Vector<Double>? {
        guard a.rows >= a.cols else {
            throw LinearAlgebraError.dimensionMismatch(
                "leastSquares: design matrix must have rows >= cols, got \(a.shapeDescription)"
            )
        }
        guard a.rows == b.count else {
            throw LinearAlgebraError.dimensionMismatch(
                "leastSquares: design matrix is \(a.shapeDescription), response has length \(b.count)"
            )
        }

        var m = Int32(a.rows)
        var n = Int32(a.cols)
        var lda = m
        var info: Int32 = 0

        // --- Step 1: A = QR (dgeqrf) ---------------------------------
        // Overwrites `aData` in place: R in the upper triangle, packed
        // Householder reflectors below it. `tau` holds the reflectors'
        // scalar factors — both are needed by dormqr in step 2.
        var aData = a.storage
        var tau = [Double](repeating: 0, count: Int(min(m, n)))

        var lwork: Int32 = -1
        var workQuery = [Double](repeating: 0, count: 1)
        dgeqrf_(&m, &n, &aData, &lda, &tau, &workQuery, &lwork, &info)
        guard info == 0 else {
            throw LinearAlgebraError.lapackError(routine: "dgeqrf (workspace query)", info: info)
        }
        lwork = Int32(workQuery[0])
        var work = [Double](repeating: 0, count: max(Int(lwork), 1))
        dgeqrf_(&m, &n, &aData, &lda, &tau, &work, &lwork, &info)
        guard info == 0 else {
            throw LinearAlgebraError.lapackError(routine: "dgeqrf", info: info)
        }

        // --- Rank check ------------------------------------------------
        // R's diagonal lives at aData[i + i*m] (column-major, ADR 0001).
        // Any near-zero entry means A doesn't have full column rank.
        for i in 0..<Int(n) {
            if abs(aData[i + i * Int(m)]) <= rankTolerance {
                return nil
            }
        }

        // --- Step 2: b <- Qᵀb (dormqr) --------------------------------
        // Applies the Householder reflectors from step 1 directly to
        // `b`, without ever materializing Q explicitly — cheaper and
        // more numerically stable than forming Q via dorgqr just to
        // multiply it out.
        var bData = b.storage
        var ldb = m
        var nrhs: Int32 = 1
        var side: Int8 = Int8(UInt8(ascii: "L"))
        var trans: Int8 = Int8(UInt8(ascii: "T"))

        var lworkQ: Int32 = -1
        var workQQuery = [Double](repeating: 0, count: 1)
        dormqr_(&side, &trans, &m, &nrhs, &n, &aData, &lda, &tau, &bData, &ldb, &workQQuery, &lworkQ, &info)
        guard info == 0 else {
            throw LinearAlgebraError.lapackError(routine: "dormqr (workspace query)", info: info)
        }
        lworkQ = Int32(workQQuery[0])
        var workQ = [Double](repeating: 0, count: max(Int(lworkQ), 1))
        dormqr_(&side, &trans, &m, &nrhs, &n, &aData, &lda, &tau, &bData, &ldb, &workQ, &lworkQ, &info)
        guard info == 0 else {
            throw LinearAlgebraError.lapackError(routine: "dormqr", info: info)
        }

        // --- Step 3: R x = (Qᵀb)[0..<n] (dtrtrs) ----------------------
        // Back-substitution against R, upper-triangular, stored in
        // aData's upper triangle from step 1.
        var uplo: Int8 = Int8(UInt8(ascii: "U"))
        var transSolve: Int8 = Int8(UInt8(ascii: "N"))
        var diag: Int8 = Int8(UInt8(ascii: "N"))
        var solvedN = n
        var solvedNrhs: Int32 = 1
        var rhs = Array(bData.prefix(Int(n)))
        var ldb2 = n

        dtrtrs_(&uplo, &transSolve, &diag, &solvedN, &solvedNrhs, &aData, &lda, &rhs, &ldb2, &info)
        guard info == 0 else {
            throw LinearAlgebraError.lapackError(routine: "dtrtrs", info: info)
        }

        return Vector(rhs)
    }
}
