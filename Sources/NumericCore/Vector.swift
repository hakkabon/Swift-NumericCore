/// A dense vector of `Scalar` elements.
///
/// Storage is a plain `[Scalar]` in v1. This is deliberate: a dedicated
/// `NCBindings`-backed buffer (shared memory with the Rust side, avoiding
/// a copy at the FFI boundary) is a real future optimization, but v1
/// prioritizes a correct, simple public API — see
/// `docs/decisions/0006-v1-storage-is-swift-array.md`.
public struct Vector<Scalar: NCScalar> {
    public private(set) var storage: [Scalar]

    public init(_ storage: [Scalar]) {
        self.storage = storage
    }

    public init(repeating value: Scalar, count: Int) {
        self.storage = [Scalar](repeating: value, count: count)
    }

    public var count: Int { storage.count }

    public subscript(index: Int) -> Scalar {
        get { storage[index] }
        set { storage[index] = newValue }
    }
}

extension Vector: Equatable where Scalar: Equatable {}

extension Vector: CustomStringConvertible {
    public var description: String {
        "Vector(\(storage))"
    }
}

// MARK: - Operations (public entry points; implementation dispatches)

extension Vector {
    /// Dot product `self · other`.
    public func dot(_ other: Vector<Scalar>) throws -> Scalar {
        guard count == other.count else {
            throw NCError.dimensionMismatch(
                "dot: vectors have lengths \(count) and \(other.count)"
            )
        }
        return try Dispatcher.dot(self, other)
    }

    /// Euclidean (L2) norm.
    public func norm() throws -> Scalar {
        try Dispatcher.norm(self, order: .l2)
    }

    /// `self + alpha * other`, i.e. axpy without mutating `self` in place.
    public func adding(_ other: Vector<Scalar>, scaledBy alpha: Scalar) throws -> Vector<Scalar> {
        guard count == other.count else {
            throw NCError.dimensionMismatch(
                "axpy: vectors have lengths \(count) and \(other.count)"
            )
        }
        var result = self
        try Dispatcher.axpy(alpha: alpha, other, into: &result)
        return result
    }
}

public enum NormOrder {
    case l1
    case l2
    case infinity
}
