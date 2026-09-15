/// Swift-facing wrapper over the generated `FfiVectorF64`/`FfiVectorF32`
/// object handles (see `nc-ffi`'s module docs and ADR 0005's update for
/// why these exist: chained `axpy`/`dot`/`norm2` calls against the same
/// data with no per-call copy across the FFI boundary).
///
/// **Additive and opt-in** — nothing in `NumericCore`'s default
/// `Matrix`/`Vector`/`Dispatcher` path uses this. It exists for a
/// future hot-loop consumer to reach for directly once a concrete need
/// is measured (an iterative solver's inner loop, or a `Swift-DataLens`
/// LOESS computation doing many vector operations against the same
/// working buffer), per ADR 0006's "don't build ahead of need" stance.
///
/// ## Naming risk, same shape as `FFIBridge.swift`
/// Written without the actual regenerated bindings available (adding
/// `FfiVectorF64`/`FfiVectorF32` to `nc-ffi` requires re-running
/// `scripts/update-ffi.sh` before `Generated/` reflects them). The
/// assumption here: a `#[uniffi::constructor]` method literally named
/// `new` becomes the Swift type's primary `init(data:)` (UniFFI's
/// documented convention for object constructors), and instance methods
/// follow the same `snake_case` → `camelCase` conversion already
/// confirmed correct for the free functions in `FFIBridge.swift`
/// (`axpy_in_place` → `axpyInPlace`, `to_vec` → `toVec`). If the real
/// generated API differs, the fix belongs in this file only.
public final class FFIVectorHandle {
    private let handle: FfiVectorF64

    public init(_ data: [Double]) {
        self.handle = FfiVectorF64(data: data)
    }

    public var count: Int {
        Int(handle.len())
    }

    public func toArray() -> [Double] {
        handle.toVec()
    }

    /// `self <- self + alpha * other`, mutating in place with no data
    /// crossing the FFI boundary beyond the two handles and `alpha`.
    public func axpy(alpha: Double, _ other: FFIVectorHandle) throws {
        do {
            try handle.axpyInPlace(alpha: alpha, other: other.handle)
        } catch let error as FfiError {
            throw error.asFFIError
        }
    }

    public func dot(_ other: FFIVectorHandle) throws -> Double {
        do {
            return try handle.dot(other: other.handle)
        } catch let error as FfiError {
            throw error.asFFIError
        }
    }

    public func norm2() -> Double {
        handle.norm2()
    }
}

/// The `Float` counterpart of `FFIVectorHandle`.
public final class FFIVectorHandleFloat {
    private let handle: FfiVectorF32

    public init(_ data: [Float]) {
        self.handle = FfiVectorF32(data: data)
    }

    public var count: Int {
        Int(handle.len())
    }

    public func toArray() -> [Float] {
        handle.toVec()
    }

    public func axpy(alpha: Float, _ other: FFIVectorHandleFloat) throws {
        do {
            try handle.axpyInPlace(alpha: alpha, other: other.handle)
        } catch let error as FfiError {
            throw error.asFFIError
        }
    }

    public func dot(_ other: FFIVectorHandleFloat) throws -> Float {
        do {
            return try handle.dot(other: other.handle)
        } catch let error as FfiError {
            throw error.asFFIError
        }
    }

    public func norm2() -> Float {
        handle.norm2()
    }
}

extension FfiError {
    fileprivate var asFFIError: FFIError {
        switch self {
        case .DimensionMismatch(let message):
            return .dimensionMismatch(message)
        }
    }
}
