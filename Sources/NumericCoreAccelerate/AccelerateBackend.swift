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
/// `axpy`/`dot`/`norm` are implemented below via `cblas_daxpy`/`cblas_saxpy`,
/// `cblas_ddot`/`cblas_sdot`, and `cblas_dnrm2`/`cblas_snrm2`.
///
/// QR decomposition and QR-based solve/least-squares are implemented in
/// `QRSolve.swift` (see that file for the LAPACK calls and an important
/// caveat about unverified parameter marshaling). LU and SVD are still
/// out of scope here —
/// see `docs/decisions/0003-decomposition-scope.md`.
///
/// ## Why the `as?` casts
/// Every method below is generic over `NCScalar`, but the underlying
/// CBLAS functions are concrete-typed C functions — there's no generic
/// BLAS entry point. Since only `Float` and `Double` conform to
/// `NCScalar` (by design, see `NCScalar`'s doc comment), each generic
/// function dispatches on `T.dispatchTypeName` and downcasts to the
/// concrete `Double`/`Float` type before calling through. This is a
/// standard pattern for bridging a generic Swift API onto a non-generic
/// C API family — the casts always succeed for the two conforming
/// types, and the `default` branch exists only to keep the compiler
/// (and a future third `NCScalar` conformance) honest.
public enum AccelerateBackend: Backend {
    public static let identifier = "accelerate"
    public static let device: ComputeDevice = .cpu
    public static let capabilities: BackendCapabilities = [.matmul, .elementwise, .reduction]

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

    // MARK: - axpy / dot / norm

    public static func axpy<T: NCScalar>(alpha: T, _ x: Vector<T>, into y: inout Vector<T>) throws {
        guard x.count == y.count else {
            throw BackendError.dimensionMismatch("axpy: lengths \(x.count) and \(y.count)")
        }

        switch T.dispatchTypeName {
        case "Double":
            guard let dAlpha = alpha as? Double, let dx = x as? Vector<Double>, var dy = y as? Vector<Double> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            axpyDouble(alpha: dAlpha, dx, into: &dy)
            guard let cast = dy as? Vector<T> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            y = cast

        case "Float":
            guard let fAlpha = alpha as? Float, let fx = x as? Vector<Float>, var fy = y as? Vector<Float> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            axpyFloat(alpha: fAlpha, fx, into: &fy)
            guard let cast = fy as? Vector<T> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            y = cast

        default:
            throw BackendError.unsupportedScalarType(T.dispatchTypeName)
        }
    }

    public static func dot<T: NCScalar>(_ x: Vector<T>, _ y: Vector<T>) throws -> T {
        guard x.count == y.count else {
            throw BackendError.dimensionMismatch("dot: lengths \(x.count) and \(y.count)")
        }

        switch T.dispatchTypeName {
        case "Double":
            guard let dx = x as? Vector<Double>, let dy = y as? Vector<Double> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            guard let cast = dotDouble(dx, dy) as? T else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            return cast

        case "Float":
            guard let fx = x as? Vector<Float>, let fy = y as? Vector<Float> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            guard let cast = dotFloat(fx, fy) as? T else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            return cast

        default:
            throw BackendError.unsupportedScalarType(T.dispatchTypeName)
        }
    }

    public static func norm<T: NCScalar>(_ x: Vector<T>, order: NormOrder) throws -> T {
        // cblas_?nrm2 is the Euclidean (L2) norm only — L1/infinity have
        // no single CBLAS call backing them (L1 would be cblas_?asum,
        // which is a different enough operation it isn't worth routing
        // through here until there's a caller). Only L2 is wired.
        guard order == .l2 else {
            throw BackendError.unsupportedOperation("accelerate.norm(order: \(order))")
        }

        switch T.dispatchTypeName {
        case "Double":
            guard let dx = x as? Vector<Double> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            guard let cast = norm2Double(dx) as? T else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            return cast

        case "Float":
            guard let fx = x as? Vector<Float> else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            guard let cast = norm2Float(fx) as? T else {
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
            return cast

        default:
            throw BackendError.unsupportedScalarType(T.dispatchTypeName)
        }
    }

    /// `y = alpha * x + y` via `cblas_daxpy`.
    private static func axpyDouble(alpha: Double, _ x: Vector<Double>, into y: inout Vector<Double>) {
        var result = y.storage
        x.storage.withUnsafeBufferPointer { xPtr in
            result.withUnsafeMutableBufferPointer { yPtr in
                cblas_daxpy(Int32(x.count), alpha, xPtr.baseAddress, 1, yPtr.baseAddress, 1)
            }
        }
        y = Vector(result)
    }

    /// `y = alpha * x + y` via `cblas_saxpy` — the `Float` counterpart.
    private static func axpyFloat(alpha: Float, _ x: Vector<Float>, into y: inout Vector<Float>) {
        var result = y.storage
        x.storage.withUnsafeBufferPointer { xPtr in
            result.withUnsafeMutableBufferPointer { yPtr in
                cblas_saxpy(Int32(x.count), alpha, xPtr.baseAddress, 1, yPtr.baseAddress, 1)
            }
        }
        y = Vector(result)
    }

    /// Dot product via `cblas_ddot`.
    private static func dotDouble(_ x: Vector<Double>, _ y: Vector<Double>) -> Double {
        x.storage.withUnsafeBufferPointer { xPtr in
            y.storage.withUnsafeBufferPointer { yPtr in
                cblas_ddot(Int32(x.count), xPtr.baseAddress, 1, yPtr.baseAddress, 1)
            }
        }
    }

    /// Dot product via `cblas_sdot` — the `Float` counterpart.
    private static func dotFloat(_ x: Vector<Float>, _ y: Vector<Float>) -> Float {
        x.storage.withUnsafeBufferPointer { xPtr in
            y.storage.withUnsafeBufferPointer { yPtr in
                cblas_sdot(Int32(x.count), xPtr.baseAddress, 1, yPtr.baseAddress, 1)
            }
        }
    }

    /// Euclidean norm via `cblas_dnrm2`.
    private static func norm2Double(_ x: Vector<Double>) -> Double {
        x.storage.withUnsafeBufferPointer { xPtr in
            cblas_dnrm2(Int32(x.count), xPtr.baseAddress, 1)
        }
    }

    /// Euclidean norm via `cblas_snrm2` — the `Float` counterpart.
    private static func norm2Float(_ x: Vector<Float>) -> Float {
        x.storage.withUnsafeBufferPointer { xPtr in
            cblas_snrm2(Int32(x.count), xPtr.baseAddress, 1)
        }
    }
}
