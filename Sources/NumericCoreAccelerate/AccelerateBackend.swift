import Accelerate
import NumericCore

/// Accelerate-backed `Backend` — wraps `vDSP`/BLAS/LAPACK.
///
/// `matmul` is implemented via `cblas_dgemm`/`cblas_sgemm` (the CBLAS
/// interface Accelerate exposes). Column-major storage (`Matrix`'s
/// documented layout, ADR 0001) is exactly what these expect, so no
/// transpose step is needed — `Matrix.storage` is passed straight
/// through as the `A`/`B`/`C` buffers.
///
/// `axpy`/`dot`/`norm` are not wired yet — `capabilities` only
/// advertises `.matmul`. Wiring those is a small addition (`vDSP_vsma`,
/// `cblas_ddot`/`cblas_sdot`, `cblas_dnrm2`/`cblas_snrm2`) but is left
/// for when there's a concrete caller exercising them, per this
/// project's "don't build ahead of need" principle.
///
/// Decompositions (LU/QR/SVD via LAPACKE) are still out of scope here —
/// see `docs/decisions/0003-decomposition-scope.md`.
///
/// ## Why the `as?` casts
/// `matmul` is generic over `NCScalar`, but `cblas_dgemm`/`cblas_sgemm`
/// are concrete-typed C functions — there's no generic BLAS entry point.
/// Since only `Float` and `Double` conform to `NCScalar` (by design, see
/// `NCScalar`'s doc comment), the generic function dispatches on
/// `T.dispatchTypeName` and downcasts to the concrete `Matrix<Double>` /
/// `Matrix<Float>` before calling through. This is a standard pattern
/// for bridging a generic Swift API onto a non-generic C API family —
/// the casts always succeed for the two conforming types, and the
/// `default` branch exists only to keep the compiler (and a future
/// third `NCScalar` conformance) honest.
public enum AccelerateBackend: Backend {
    public static let identifier = "accelerate"
    public static let device: ComputeDevice = .cpu
    public static let capabilities: BackendCapabilities = [.matmul]

    public static func isAvailable() -> Bool {
        // Accelerate is always present on Apple platforms within this
        // package's deployment targets (macOS 13+, iOS 16+).
        true
    }

    public static func matmul<T: NCScalar>(_ a: Matrix<T>, _ b: Matrix<T>, into result: inout Matrix<T>) throws {
        guard a.cols == b.rows, result.rows == a.rows, result.cols == b.cols else {
            throw BackendError.dimensionMismatch(
                "matmul: \(a.shapeDescription) * \(b.shapeDescription) -> \(result.shapeDescription)"
            )
        }

        switch T.dispatchTypeName {
        case "Double":
            guard let da = a as? Matrix<Double>, let db = b as? Matrix<Double> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            let computed = gemmDouble(da, db)
            guard let cast = computed as? Matrix<T> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            result = cast

        case "Float":
            guard let fa = a as? Matrix<Float>, let fb = b as? Matrix<Float> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            let computed = gemmFloat(fa, fb)
            guard let cast = computed as? Matrix<T> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            result = cast

        default:
            throw BackendError.unsupportedScalarType(T.dispatchTypeName)
        }
    }

    /// `C = A * B` via `cblas_dgemm`, column-major, no transpose.
    private static func gemmDouble(_ a: Matrix<Double>, _ b: Matrix<Double>) -> Matrix<Double> {
        let m = Int32(a.rows)
        let k = Int32(a.cols)
        let n = Int32(b.cols)
        var c = [Double](repeating: 0, count: Int(m) * Int(n))

        a.storage.withUnsafeBufferPointer { aPtr in
            b.storage.withUnsafeBufferPointer { bPtr in
                c.withUnsafeMutableBufferPointer { cPtr in
                    cblas_dgemm(
                        CblasColMajor, CblasNoTrans, CblasNoTrans,
                        m, n, k,
                        1.0,
                        aPtr.baseAddress, m,
                        bPtr.baseAddress, k,
                        0.0,
                        cPtr.baseAddress, m
                    )
                }
            }
        }
        // Safe to force-try: c.count == m * n by construction above.
        return try! Matrix(rows: Int(m), cols: Int(n), storage: c)
    }

    /// `C = A * B` via `cblas_sgemm` — the `Float` counterpart of `gemmDouble`.
    private static func gemmFloat(_ a: Matrix<Float>, _ b: Matrix<Float>) -> Matrix<Float> {
        let m = Int32(a.rows)
        let k = Int32(a.cols)
        let n = Int32(b.cols)
        var c = [Float](repeating: 0, count: Int(m) * Int(n))

        a.storage.withUnsafeBufferPointer { aPtr in
            b.storage.withUnsafeBufferPointer { bPtr in
                c.withUnsafeMutableBufferPointer { cPtr in
                    cblas_sgemm(
                        CblasColMajor, CblasNoTrans, CblasNoTrans,
                        m, n, k,
                        1.0,
                        aPtr.baseAddress, m,
                        bPtr.baseAddress, k,
                        0.0,
                        cPtr.baseAddress, m
                    )
                }
            }
        }
        return try! Matrix(rows: Int(m), cols: Int(n), storage: c)
    }
}
