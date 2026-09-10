/// The universal fallback backend — always available, no external
/// framework dependency. v1 implements it directly in Swift (mirroring
/// `nc-kernels-generic`'s algorithms) so `NumericCore` alone (without
/// `NumericCoreAccelerate`) is already a complete, correct, if slow,
/// implementation.
///
/// Once `NCBindings` exposes real UniFFI calls into `nc-kernels-generic`
/// / `nc-kernels-simd`, swap this type's method bodies to call through
/// rather than reimplementing — kept as pure Swift for now so the
/// `Backend` protocol and `Dispatcher` can be exercised without the FFI
/// layer being finished first. See `docs/decisions/0005-ffi-uniffi.md`.
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
        // Naive column-major triple loop — see nc-kernels-generic::matmul
        // for the Rust equivalent this mirrors. Not optimized; correctness
        // oracle and portability path, not a performance path.
        for j in 0..<b.cols {
            for p in 0..<a.cols {
                let bpj = b[p, j]
                for i in 0..<a.rows {
                    result[i, j] += a[i, p] * bpj
                }
            }
        }
    }

    public static func axpy<T: NCScalar>(alpha: T, _ x: Vector<T>, into y: inout Vector<T>) throws {
        guard x.count == y.count else {
            throw BackendError.dimensionMismatch("axpy: lengths \(x.count) and \(y.count)")
        }
        for i in 0..<x.count {
            y[i] += alpha * x[i]
        }
    }

    public static func dot<T: NCScalar>(_ x: Vector<T>, _ y: Vector<T>) throws -> T {
        guard x.count == y.count else {
            throw BackendError.dimensionMismatch("dot: lengths \(x.count) and \(y.count)")
        }
        var acc = T.zero
        for i in 0..<x.count {
            acc += x[i] * y[i]
        }
        return acc
    }

    public static func norm<T: NCScalar>(_ x: Vector<T>, order: NormOrder) throws -> T {
        switch order {
        case .l2:
            return try dot(x, x).squareRoot()
        case .l1, .infinity:
            throw BackendError.unsupportedOperation("fallback.norm(order: \(order))")
        }
    }
}
