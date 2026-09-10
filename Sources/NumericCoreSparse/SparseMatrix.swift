import NumericCore

/// Compressed Sparse Row matrix — the Swift-facing counterpart of
/// `nc-sparse::CsrMatrix`.
///
/// v1 storage is plain Swift arrays, mirroring `Matrix<T>`'s choice to
/// defer `NCBindings`-backed shared storage (see
/// `docs/decisions/0006-v1-storage-is-swift-array.md`). Once `nc-ffi`
/// exposes real UniFFI bindings for `nc-sparse`, this type's storage and
/// `spmv` implementation should move to calling through rather than
/// reimplementing — kept as pure Swift for now so this type and
/// `NumericCoreGraph` (its first consumer) can be built and tested
/// end-to-end without waiting on the FFI layer.
///
/// Only CSR is implemented in v1 — see
/// `docs/decisions/0002-sparse-v1-scope.md` for why COO/CSC are deferred.
public struct SparseMatrix<Scalar: NCScalar> {
    public let rows: Int
    public let cols: Int
    private let rowPointers: [Int]   // length rows + 1
    private let columnIndices: [Int] // length nnz
    private let values: [Scalar]     // length nnz

    public init(rows: Int, cols: Int, rowPointers: [Int], columnIndices: [Int], values: [Scalar]) throws {
        guard rowPointers.count == rows + 1 else {
            throw NCError.dimensionMismatch(
                "SparseMatrix: rowPointers needs \(rows + 1) entries, got \(rowPointers.count)"
            )
        }
        guard columnIndices.count == values.count else {
            throw NCError.dimensionMismatch(
                "SparseMatrix: columnIndices (\(columnIndices.count)) and values (\(values.count)) length mismatch"
            )
        }
        guard columnIndices.allSatisfy({ $0 >= 0 && $0 < cols }) else {
            throw NCError.dimensionMismatch("SparseMatrix: a column index is out of bounds for \(cols) columns")
        }
        self.rows = rows
        self.cols = cols
        self.rowPointers = rowPointers
        self.columnIndices = columnIndices
        self.values = values
    }

    public var nonZeroCount: Int { values.count }

    /// Sparse matrix-vector product: `result = self * x`.
    public func multiplying(_ x: Vector<Scalar>) throws -> Vector<Scalar> {
        guard x.count == cols else {
            throw NCError.dimensionMismatch("spmv: matrix is \(rows)x\(cols), vector has length \(x.count)")
        }
        var result = Vector<Scalar>(repeating: .zero, count: rows)
        for row in 0..<rows {
            var acc = Scalar.zero
            for idx in rowPointers[row]..<rowPointers[row + 1] {
                acc += values[idx] * x[columnIndices[idx]]
            }
            result[row] = acc
        }
        return result
    }
}
