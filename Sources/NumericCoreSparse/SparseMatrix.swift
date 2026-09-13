import NCBindings
import NumericCore

/// Compressed Sparse Row matrix — the Swift-facing counterpart of
/// `nc-sparse::CsrMatrix`.
///
/// `multiplying(_:)` (SpMV) now calls through to the Rust core
/// (`nc-sparse::CsrMatrix::spmv`, via `NCBindings.FFIKernels`) for both
/// `Double` and `Float` — the duplication ADR 0006 flagged as accepted
/// debt is fully retired, mirroring the same rewiring done for
/// `RustFallbackBackend`. There is no pure-Swift SpMV implementation
/// left in this file.
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

        do {
            switch Scalar.dispatchTypeName {
            case "Double":
                guard let doubleValues = values as? [Double], let doubleX = x as? Vector<Double> else {
                    throw NCError.unsupportedScalarType(Scalar.dispatchTypeName)
                }
                let resultData = try FFIKernels.spmv(
                    rows: rows, cols: cols,
                    rowPointers: rowPointers, columnIndices: columnIndices,
                    values: doubleValues, x: doubleX.storage
                )
                guard let cast = Vector(resultData) as? Vector<Scalar> else {
                    throw NCError.unsupportedScalarType(Scalar.dispatchTypeName)
                }
                return cast

            case "Float":
                guard let floatValues = values as? [Float], let floatX = x as? Vector<Float> else {
                    throw NCError.unsupportedScalarType(Scalar.dispatchTypeName)
                }
                let resultData = try FFIKernels.spmvFloat(
                    rows: rows, cols: cols,
                    rowPointers: rowPointers, columnIndices: columnIndices,
                    values: floatValues, x: floatX.storage
                )
                guard let cast = Vector(resultData) as? Vector<Scalar> else {
                    throw NCError.unsupportedScalarType(Scalar.dispatchTypeName)
                }
                return cast

            default:
                throw NCError.unsupportedScalarType(Scalar.dispatchTypeName)
            }
        } catch let error as FFIError {
            throw error.asNCError
        }
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
