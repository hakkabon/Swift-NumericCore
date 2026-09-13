import NCBindings

/// The universal fallback backend — always available, no Accelerate/MPS
/// dependency.
///
/// Both `Double` and `Float` now genuinely call through to the Rust
/// core (`nc-kernels-generic`, via `NCBindings.FFIKernels`) — the
/// Swift/Rust duplication ADR 0006 flagged as accepted debt is fully
/// retired as of `nc-ffi` gaining `f32` exports alongside the original
/// `f64` ones. There is no pure-Swift numeric implementation left in
/// this file; any future `NCScalar` conformance beyond these two would
/// need its own FFI export added in `nc-ffi` first (following the exact
/// pattern already established for `f32`/`f64`) before it could be
/// supported here.
///
/// This type's identifier stays `"fallback"` and its public API is
/// unchanged from before this rewiring — existing `Dispatcher`
/// registrations and tests referencing `RustFallbackBackend.self`
/// continue to work without modification.
public enum RustFallbackBackend: Backend {
    public static let identifier = "fallback"
    public static let device: ComputeDevice = .cpu
    public static let capabilities: BackendCapabilities = [.matmul, .elementwise, .reduction]

    public static func isAvailable() -> Bool { true }

    public static func matmul<T: NCScalar>(_ a: Matrix<T>, _ b: Matrix<T>, into result: inout Matrix<T>) throws {
        guard a.cols == b.rows, result.rows == a.rows, result.cols == b.cols else {
            throw BackendError.dimensionMismatch(
                "matmul: \(a.shapeDescription) * \(b.shapeDescription) -> \(result.shapeDescription)"
            )
        }

        do {
            switch T.dispatchTypeName {
            case "Double":
                guard let da = a as? Matrix<Double>, let db = b as? Matrix<Double> else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                let ffiResult = try FFIKernels.matmul(
                    FFIMatrix(rows: da.rows, cols: da.cols, data: da.storage),
                    FFIMatrix(rows: db.rows, cols: db.cols, data: db.storage)
                )
                let computed = try Matrix<Double>(rows: ffiResult.rows, cols: ffiResult.cols, storage: ffiResult.data)
                guard let cast = computed as? Matrix<T> else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                result = cast

            case "Float":
                guard let fa = a as? Matrix<Float>, let fb = b as? Matrix<Float> else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                let ffiResult = try FFIKernels.matmulFloat(
                    FFIMatrixFloat(rows: fa.rows, cols: fa.cols, data: fa.storage),
                    FFIMatrixFloat(rows: fb.rows, cols: fb.cols, data: fb.storage)
                )
                let computed = try Matrix<Float>(rows: ffiResult.rows, cols: ffiResult.cols, storage: ffiResult.data)
                guard let cast = computed as? Matrix<T> else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                result = cast

            default:
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
        } catch let error as FFIError {
            throw error.asBackendError
        }
        // Any other thrown error (e.g. the NCError from a Matrix
        // initializer above, which only fails if the FFI layer returned
        // an internally-inconsistent shape — a bug in nc-ffi, not a
        // normal runtime condition) propagates as-is.
    }

    public static func axpy<T: NCScalar>(alpha: T, _ x: Vector<T>, into y: inout Vector<T>) throws {
        guard x.count == y.count else {
            throw BackendError.dimensionMismatch("axpy: lengths \(x.count) and \(y.count)")
        }

        do {
            switch T.dispatchTypeName {
            case "Double":
                guard let dAlpha = alpha as? Double, let dx = x as? Vector<Double>, let dy = y as? Vector<Double> else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                let resultData = try FFIKernels.axpy(alpha: dAlpha, dx.storage, dy.storage)
                guard let cast = Vector(resultData) as? Vector<T> else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                y = cast

            case "Float":
                guard let fAlpha = alpha as? Float, let fx = x as? Vector<Float>, let fy = y as? Vector<Float> else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                let resultData = try FFIKernels.axpyFloat(alpha: fAlpha, fx.storage, fy.storage)
                guard let cast = Vector(resultData) as? Vector<T> else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                y = cast

            default:
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
        } catch let error as FFIError {
            throw error.asBackendError
        }
    }

    public static func dot<T: NCScalar>(_ x: Vector<T>, _ y: Vector<T>) throws -> T {
        guard x.count == y.count else {
            throw BackendError.dimensionMismatch("dot: lengths \(x.count) and \(y.count)")
        }

        do {
            switch T.dispatchTypeName {
            case "Double":
                guard let dx = x as? Vector<Double>, let dy = y as? Vector<Double> else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                guard let cast = try FFIKernels.dot(dx.storage, dy.storage) as? T else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                return cast

            case "Float":
                guard let fx = x as? Vector<Float>, let fy = y as? Vector<Float> else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                guard let cast = try FFIKernels.dotFloat(fx.storage, fy.storage) as? T else {
                    throw BackendError.unsupportedScalarType(T.dispatchTypeName)
                }
                return cast

            default:
                throw BackendError.unsupportedScalarType(T.dispatchTypeName)
            }
        } catch let error as FFIError {
            throw error.asBackendError
        }
    }

    public static func norm<T: NCScalar>(_ x: Vector<T>, order: NormOrder) throws -> T {
        switch order {
        case .l2:
            // Routes through `dot` above, so this is FFI-backed for
            // both Double and Float automatically — no separate
            // dispatch needed here.
            return try dot(x, x).squareRoot()
        case .l1, .infinity:
            throw BackendError.unsupportedOperation("fallback.norm(order: \(order))")
        }
    }
}

extension FFIError {
    fileprivate var asBackendError: BackendError {
        switch self {
        case .dimensionMismatch(let message):
            return .dimensionMismatch(message)
        case .unknown(let message):
            return .unsupportedOperation(message)
        }
    }
}
