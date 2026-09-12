/// A dense, column-major matrix of `Scalar` elements.
///
/// **Column-major** to match BLAS/LAPACK's Fortran heritage, which is
/// what `NumericCoreAccelerate` calls into directly — see
/// `docs/decisions/0001-column-major-layout.md`. This means `storage[i +
/// j * rows]` is element `(i, j)`, not `storage[i * cols + j]`.
///
/// Sparse matrices are a distinct type (`NumericCoreSparse.SparseMatrix`,
/// backed by `nc-sparse`'s CSR) rather than a flag on this type — dense
/// and sparse have different enough operation sets and performance
/// characteristics that unifying them behind one Swift type would leak
/// complexity into every call site.
public struct Matrix<Scalar: NCScalar> {
    public let rows: Int
    public let cols: Int
    public private(set) var storage: [Scalar]

    /// `storage` must already be in column-major order and have exactly
    /// `rows * cols` elements.
    public init(rows: Int, cols: Int, storage: [Scalar]) throws {
        guard storage.count == rows * cols else {
            throw NCError.dimensionMismatch(
                "Matrix(rows: \(rows), cols: \(cols)) needs \(rows * cols) elements, got \(storage.count)"
            )
        }
        self.rows = rows
        self.cols = cols
        self.storage = storage
    }

    public init(rows: Int, cols: Int, repeating value: Scalar = .zero) {
        self.rows = rows
        self.cols = cols
        self.storage = [Scalar](repeating: value, count: rows * cols)
    }

    /// Build from a row-major nested array — `[[1, 2], [3, 4]]` is the
    /// matrix `[[1, 2], [3, 4]]`, matching how most callers naturally
    /// write matrix literals (and how APIs like `Swift-DataLens`'s
    /// `LinAlg.leastSquares(design: [[Double]], ...)` already receive
    /// their data). Internally converts to this type's column-major
    /// storage (ADR 0001) — the row-major/column-major distinction is
    /// this initializer's problem to solve, not the caller's.
    ///
    /// All rows must have equal length. Throws `.dimensionMismatch` on
    /// an empty outer array, a ragged inner array, or a zero-length row.
    public init(rows rowArrays: [[Scalar]]) throws {
        guard let firstRow = rowArrays.first else {
            throw NCError.dimensionMismatch("Matrix(rows:): no rows given")
        }
        let cols = firstRow.count
        guard cols > 0 else {
            throw NCError.dimensionMismatch("Matrix(rows:): rows must be non-empty")
        }
        guard rowArrays.allSatisfy({ $0.count == cols }) else {
            throw NCError.dimensionMismatch("Matrix(rows:): all rows must have the same length")
        }

        let rows = rowArrays.count
        var storage = [Scalar](repeating: .zero, count: rows * cols)
        for (r, rowValues) in rowArrays.enumerated() {
            for (c, value) in rowValues.enumerated() {
                storage[r + c * rows] = value
            }
        }
        self.rows = rows
        self.cols = cols
        self.storage = storage
    }

    /// The inverse of `init(rows:)` — a row-major nested-array view,
    /// for handing results back to callers (like `Swift-DataLens`) that
    /// work in that representation rather than `Matrix<Scalar>` directly.
    public var rowMajorArray: [[Scalar]] {
        (0..<rows).map { r in (0..<cols).map { c in self[r, c] } }
    }

    @inline(__always)
    private func index(_ row: Int, _ col: Int) -> Int {
        row + col * rows
    }

    public subscript(row: Int, col: Int) -> Scalar {
        get {
            precondition(row >= 0 && row < rows && col >= 0 && col < cols, "index out of bounds")
            return storage[index(row, col)]
        }
        set {
            precondition(row >= 0 && row < rows && col >= 0 && col < cols, "index out of bounds")
            storage[index(row, col)] = newValue
        }
    }

    public var isSparse: Bool { false }

    public var shapeDescription: String { "\(rows)x\(cols)" }
}

extension Matrix: Equatable where Scalar: Equatable {}

extension Matrix: CustomStringConvertible {
    public var description: String {
        "Matrix<\(Scalar.dispatchTypeName)>(\(rows)x\(cols))"
    }
}

// MARK: - Operations (public entry points; implementation dispatches)

extension Matrix {
    /// Matrix product `self * other`.
    public static func * (lhs: Matrix<Scalar>, rhs: Matrix<Scalar>) throws -> Matrix<Scalar> {
        guard lhs.cols == rhs.rows else {
            throw NCError.dimensionMismatch(
                "matmul: \(lhs.shapeDescription) * \(rhs.shapeDescription)"
            )
        }
        return try Dispatcher.matmul(lhs, rhs)
    }
}
