import NCBindings
import NumericCore

/// Compressed Sparse Row matrix — the Swift-facing counterpart of
/// `nc-sparse::CsrMatrix`.
///
/// For `Scalar == Double`, `multiplying(_:)` now calls through to the
/// Rust core (`nc-sparse::CsrMatrix::spmv`, via `NCBindings.FFIKernels.spmv`)
/// — the duplication ADR 0006 flagged as accepted debt is retired for
/// that case, mirroring the same rewiring done for `RustFallbackBackend`.
/// Any other `Scalar` (i.e. `Float`, since no `f32` FFI export exists
/// yet) still runs the pure-Swift loop below.
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

        if Scalar.dispatchTypeName == "Double",
           let doubleValues = values as? [Double],
           let doubleX = x as? Vector<Double> {
            do {
                let resultData = try FFIKernels.spmv(
                    rows: rows, cols: cols,
                    rowPointers: rowPointers, columnIndices: columnIndices,
                    values: doubleValues, x: doubleX.storage
                )
                guard let cast = Vector(resultData) as? Vector<Scalar> else {
                    throw NCError.unsupportedScalarType(Scalar.dispatchTypeName)
                }
                return cast
            } catch let error as FFIError {
                throw error.asNCError
            }
        }

        return try swiftSpmv(x)
    }

    /// The original pure-Swift loop, kept for `Float` (no `f32` FFI
    /// export exists yet) and any future non-Double `NCScalar`.
    private func swiftSpmv(_ x: Vector<Scalar>) throws -> Vector<Scalar> {
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

extension FFIError {
    fileprivate var asNCError: NCError {
        switch self {
        case .dimensionMismatch(let message):
            return .dimensionMismatch(message)
        case .unknown(let message):
            return .unsupportedOperation(message)
        }
    }
}
