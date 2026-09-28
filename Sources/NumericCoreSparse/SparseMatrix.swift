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
/// Storage is canonical CSR. Coordinate entries are accepted for incremental
/// assembly and normalized by sorting, duplicate coalescing, and zero removal.
public struct SparseMatrix<Scalar: NCScalar> {
    public let rows: Int
    public let cols: Int
    private let rowPointers: [Int]   // length rows + 1
    private let columnIndices: [Int] // length nnz
    private let values: [Scalar]     // length nnz

    public init(rows: Int, cols: Int, rowPointers: [Int], columnIndices: [Int], values: [Scalar]) throws {
        guard rows >= 0, cols >= 0 else {
            throw NCError.dimensionMismatch("SparseMatrix dimensions must be non-negative")
        }
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
        guard rowPointers.first == 0,
              rowPointers.last == values.count,
              rowPointers.allSatisfy({ (0...values.count).contains($0) }),
              zip(rowPointers, rowPointers.dropFirst()).allSatisfy({ $0 <= $1 })
        else {
            throw NCError.dimensionMismatch("SparseMatrix rowPointers must be monotonic from zero through nnz")
        }
        self.rows = rows
        self.cols = cols
        self.rowPointers = rowPointers
        self.columnIndices = columnIndices
        self.values = values
    }

    public var nonZeroCount: Int { values.count }

    /// Raw CSR components — exposed for `NumericCoreAMPL`'s `Presolve.swift`,
    /// which needs to hand a constraint matrix's raw arrays to
    /// `NCBindings.FFIProblem` when solving via `NCBindings.FFIKernels.solveLPSimplex`/
    /// `.solveLPInteriorPoint`. Read-only — `SparseMatrix` stays
    /// otherwise immutable.
    public var csrRowPointers: [Int] { rowPointers }
    public var csrColumnIndices: [Int] { columnIndices }
    public var csrValues: [Scalar] { values }

    /// Construct canonical CSR from unordered coordinate entries.
    public init(rows: Int, cols: Int, entries: [SparseEntry<Scalar>]) throws {
        guard rows >= 0, cols >= 0 else {
            throw NCError.dimensionMismatch("SparseMatrix dimensions must be non-negative")
        }
        var combined: [SparseCoordinate: Scalar] = [:]
        for entry in entries {
            guard (0..<rows).contains(entry.row), (0..<cols).contains(entry.column) else {
                throw NCError.dimensionMismatch("SparseMatrix coordinate is outside \(rows)x\(cols)")
            }
            combined[SparseCoordinate(row: entry.row, column: entry.column), default: .zero] += entry.value
        }
        let canonical = combined.filter { $0.value != .zero }.sorted {
            ($0.key.row, $0.key.column) < ($1.key.row, $1.key.column)
        }
        var rowPointers = [Int](repeating: 0, count: rows + 1)
        var columnIndices: [Int] = []
        var values: [Scalar] = []
        columnIndices.reserveCapacity(canonical.count)
        values.reserveCapacity(canonical.count)
        for (coordinate, value) in canonical {
            rowPointers[coordinate.row + 1] += 1
            columnIndices.append(coordinate.column)
            values.append(value)
        }
        for row in 0..<rows { rowPointers[row + 1] += rowPointers[row] }
        try self.init(
            rows: rows, cols: cols, rowPointers: rowPointers,
            columnIndices: columnIndices, values: values
        )
    }

    /// Materialize the transpose as canonical CSR.
    public func transposed() throws -> SparseMatrix<Scalar> {
        var entries: [SparseEntry<Scalar>] = []
        entries.reserveCapacity(nonZeroCount)
        for row in 0..<rows {
            for index in rowPointers[row]..<rowPointers[row + 1] {
                entries.append(SparseEntry(
                    row: columnIndices[index], column: row, value: values[index]
                ))
            }
        }
        return try SparseMatrix(rows: cols, cols: rows, entries: entries)
    }

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

public struct SparseEntry<Scalar: NCScalar>: Sendable where Scalar: Sendable {
    public let row: Int
    public let column: Int
    public let value: Scalar

    public init(row: Int, column: Int, value: Scalar) {
        self.row = row
        self.column = column
        self.value = value
    }
}

private struct SparseCoordinate: Hashable {
    let row: Int
    let column: Int
}

extension FFIError {
    fileprivate var asNCError: NCError {
        switch self {
        case .dimensionMismatch(let message):
            return .dimensionMismatch(message)
        case .solverError(let message):
            return .unsupportedOperation(message)
        case .unknown(let message):
            return .unsupportedOperation(message)
        }
    }
}
