/// The single call-through point `Matrix`/`Vector` operations use. Holds
/// the active `DispatchPolicy` and the list of registered backends, and
/// translates `BackendError` into the public `NCError` so callers never
/// need to know which backend actually ran.
public enum Dispatcher {
    /// Mutable so tests / benchmarking tools can swap it out; not
    /// thread-synchronized in v1 — see
    /// `docs/decisions/0007-dispatcher-concurrency.md` for why this is an
    /// acceptable v1 gap (single-threaded numeric pipelines are the
    /// initial target) and what to do before that changes.
    public static var policy: DispatchPolicy = .default

    /// Backends considered for dispatch, most-preferred first.
    /// `RustFallbackBackend` is never listed here — `DispatchPolicy`
    /// appends it automatically as the universal last resort. Append
    /// `AccelerateBackend.self` / `MPSBackend.self` here once those
    /// packages exist and are imported by the consuming app.
    public static var registeredBackends: [any Backend.Type] = []

    public static func matmul<T: NCScalar>(_ a: Matrix<T>, _ b: Matrix<T>) throws -> Matrix<T> {
        let backend = policy.chooseBackend(
            for: .matmul,
            elementCount: a.rows * b.cols,
            scalarTypeName: T.dispatchTypeName,
            sparse: a.isSparse || b.isSparse,
            candidates: registeredBackends
        )

        var result = Matrix<T>(rows: a.rows, cols: b.cols)
        do {
            try backend.matmul(a, b, into: &result)
        } catch let error as BackendError {
            throw error.asNCError
        }
        return result
    }

    public static func axpy<T: NCScalar>(alpha: T, _ x: Vector<T>, into y: inout Vector<T>) throws {
        let backend = policy.chooseBackend(
            for: .elementwise,
            elementCount: x.count,
            scalarTypeName: T.dispatchTypeName,
            sparse: false,
            candidates: registeredBackends
        )
        do {
            try backend.axpy(alpha: alpha, x, into: &y)
        } catch let error as BackendError {
            throw error.asNCError
        }
    }

    public static func dot<T: NCScalar>(_ x: Vector<T>, _ y: Vector<T>) throws -> T {
        let backend = policy.chooseBackend(
            for: .reduction,
            elementCount: x.count,
            scalarTypeName: T.dispatchTypeName,
            sparse: false,
            candidates: registeredBackends
        )
        do {
            return try backend.dot(x, y)
        } catch let error as BackendError {
            throw error.asNCError
        }
    }

    public static func norm<T: NCScalar>(_ x: Vector<T>, order: NormOrder) throws -> T {
        let backend = policy.chooseBackend(
            for: .reduction,
            elementCount: x.count,
            scalarTypeName: T.dispatchTypeName,
            sparse: false,
            candidates: registeredBackends
        )
        do {
            return try backend.norm(x, order: order)
        } catch let error as BackendError {
            throw error.asNCError
        }
    }
}

extension BackendError {
    fileprivate var asNCError: NCError {
        switch self {
        case .unsupportedOperation(let op):
            return .unsupportedOperation(op)
        case .unsupportedScalarType(let type):
            return .unsupportedScalarType(type)
        case .dimensionMismatch(let detail):
            return .dimensionMismatch(detail)
        }
    }
}
