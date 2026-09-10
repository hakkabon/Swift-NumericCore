/// Which kind of compute device a `Backend` runs on. Informational —
/// `DispatchPolicy` uses `capabilities` and `isAvailable()`, not `device`,
/// to decide; `device` exists for logging/benchmarking output.
public enum ComputeDevice {
    case cpu
    case gpu
}

/// What a `Backend` can do. `DispatchPolicy` checks this before routing
/// an operation to a backend, so a backend that only implements a subset
/// of operations (e.g. `NumericCoreRustBackend` has no GPU path; a future
/// sparse-only backend might only implement `.sparse`) is never asked to
/// do something it can't.
public struct BackendCapabilities: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let matmul        = BackendCapabilities(rawValue: 1 << 0)
    public static let decomposition = BackendCapabilities(rawValue: 1 << 1)
    public static let sparse        = BackendCapabilities(rawValue: 1 << 2)
    public static let elementwise   = BackendCapabilities(rawValue: 1 << 3)
    public static let reduction     = BackendCapabilities(rawValue: 1 << 4)
}

/// Errors internal to a backend implementation. `Dispatcher` catches
/// these and re-throws as `NCError` so callers of `Matrix`/`Vector` only
/// ever see one error type regardless of which backend ran.
public enum BackendError: Error {
    case unsupportedOperation(String)
    case unsupportedScalarType(String)
    case dimensionMismatch(String)
}

/// A compute backend: Accelerate, MPS, or the pure-Swift/Rust fallback.
///
/// Every method has a default implementation that throws
/// `.unsupportedOperation` — a new backend only needs to implement the
/// operations its `capabilities` actually advertise. `DispatchPolicy`
/// checks capabilities before calling, so the default is a defensive
/// backstop, not the expected path.
public protocol Backend {
    static var identifier: String { get }
    static var device: ComputeDevice { get }
    static var capabilities: BackendCapabilities { get }

    /// Cheap, synchronous check — no allocation, no device queries beyond
    /// what's trivially cached. Called on every dispatch, so it must stay
    /// fast; if a backend needs an expensive one-time check (e.g. "is
    /// Metal available on this device"), cache that result statically and
    /// have this just read the cache.
    static func isAvailable() -> Bool

    static func matmul<T: NCScalar>(_ a: Matrix<T>, _ b: Matrix<T>, into result: inout Matrix<T>) throws
    static func axpy<T: NCScalar>(alpha: T, _ x: Vector<T>, into y: inout Vector<T>) throws
    static func dot<T: NCScalar>(_ x: Vector<T>, _ y: Vector<T>) throws -> T
    static func norm<T: NCScalar>(_ x: Vector<T>, order: NormOrder) throws -> T
}

extension Backend {
    public static func matmul<T: NCScalar>(_ a: Matrix<T>, _ b: Matrix<T>, into result: inout Matrix<T>) throws {
        throw BackendError.unsupportedOperation("\(identifier).matmul")
    }

    public static func axpy<T: NCScalar>(alpha: T, _ x: Vector<T>, into y: inout Vector<T>) throws {
        throw BackendError.unsupportedOperation("\(identifier).axpy")
    }

    public static func dot<T: NCScalar>(_ x: Vector<T>, _ y: Vector<T>) throws -> T {
        throw BackendError.unsupportedOperation("\(identifier).dot")
    }

    public static func norm<T: NCScalar>(_ x: Vector<T>, order: NormOrder) throws -> T {
        throw BackendError.unsupportedOperation("\(identifier).norm")
    }
}
