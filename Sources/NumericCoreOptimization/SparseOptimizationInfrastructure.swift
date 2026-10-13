import Foundation
import NCBindings

public struct SparseLinearProblem: Sendable, Hashable {
    public let objective: [Double]
    public let rows: Int
    public let columns: Int
    public let rowPointers: [Int]
    public let columnIndices: [Int]
    public let values: [Double]
    public let rowBounds: [ParameterBound]
    public let variableBounds: [ParameterBound]
    public let isInteger: [Bool]

    public init(objective: [Double], rows: Int, columns: Int, rowPointers: [Int],
                columnIndices: [Int], values: [Double], rowBounds: [ParameterBound],
                variableBounds: [ParameterBound], isInteger: [Bool]? = nil) throws {
        self.objective = objective; self.rows = rows; self.columns = columns
        self.rowPointers = rowPointers; self.columnIndices = columnIndices; self.values = values
        self.rowBounds = rowBounds; self.variableBounds = variableBounds
        self.isInteger = isInteger ?? [Bool](repeating: false, count: columns)
        try validate()
    }

    public func validate() throws {
        guard rows >= 0, columns > 0, objective.count == columns,
              rowBounds.count == rows, variableBounds.count == columns,
              isInteger.count == columns, rowPointers.count == rows + 1,
              rowPointers.first == 0, rowPointers.last == values.count,
              columnIndices.count == values.count,
              zip(rowPointers, rowPointers.dropFirst()).allSatisfy({ $0 <= $1 }),
              rowPointers.allSatisfy({ (0...values.count).contains($0) }),
              columnIndices.allSatisfy({ (0..<columns).contains($0) }),
              (objective + values).allSatisfy(\.isFinite),
              (rowBounds + variableBounds).allSatisfy(sparseValidBound) else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid sparse LP structure")
        }
    }

    fileprivate var ffi: FFIProblem {
        FFIProblem(objective: objective, constraintRows: rows, constraintCols: columns,
                   constraintRowPointers: rowPointers, constraintColumnIndices: columnIndices,
                   constraintValues: values,
                   rowBounds: rowBounds.map { .init(lower: $0.lower, upper: $0.upper) },
                   varBounds: variableBounds.map { .init(lower: $0.lower, upper: $0.upper) },
                   isInteger: isInteger)
    }
}

/// Holds both CSR and its column-oriented transpose for repeated LP operations.
public struct SparseLinearWorkspace: Sendable, Hashable {
    public let problem: SparseLinearProblem
    private let transposeRowPointers: [Int]
    private let transposeColumnIndices: [Int]
    private let transposeValues: [Double]

    public init(problem: SparseLinearProblem) throws {
        try problem.validate(); self.problem = problem
        var counts = [Int](repeating: 0, count: problem.columns)
        for column in problem.columnIndices { counts[column] += 1 }
        var pointers = [Int](repeating: 0, count: problem.columns + 1)
        for i in counts.indices { pointers[i + 1] = pointers[i] + counts[i] }
        var next = Array(pointers.dropLast())
        var indices = [Int](repeating: 0, count: problem.values.count)
        var values = [Double](repeating: 0, count: problem.values.count)
        for row in 0..<problem.rows {
            for index in problem.rowPointers[row]..<problem.rowPointers[row + 1] {
                let column = problem.columnIndices[index], target = next[column]
                indices[target] = row; values[target] = problem.values[index]; next[column] += 1
            }
        }
        transposeRowPointers = pointers; transposeColumnIndices = indices
        transposeValues = values
    }

    public var nonzeros: Int { problem.values.count }
    public func rowActivity(_ point: [Double]) throws -> [Double] {
        guard point.count == problem.columns else {
            throw NonlinearOptimizationError.invalidConfiguration("sparse LP point dimension mismatch")
        }
        return sparseMultiply(rows: problem.rows, pointers: problem.rowPointers,
                              columns: problem.columnIndices, values: problem.values, vector: point)
    }
    public func transposeProduct(_ rowValues: [Double]) throws -> [Double] {
        guard rowValues.count == problem.rows else {
            throw NonlinearOptimizationError.invalidConfiguration("sparse LP row-vector dimension mismatch")
        }
        return sparseMultiply(rows: problem.columns, pointers: transposeRowPointers,
                              columns: transposeColumnIndices, values: transposeValues,
                              vector: rowValues)
    }
}

public enum SparseLinearSolver {
    public static func solveSimplex(_ problem: SparseLinearProblem,
                                    options: FFISimplexOptions = .init()) throws -> FFISolution {
        try problem.validate(); return try FFIKernels.solveLPSimplex(problem.ffi, options: options)
    }
    public static func solveInteriorPoint(
        _ problem: SparseLinearProblem,
        options: FFIInteriorPointOptions = .init()
    ) throws -> FFISolution {
        try problem.validate()
        return try FFIKernels.solveLPInteriorPoint(problem.ffi, options: options)
    }
}

/// Canonical lower-triangular CSR storage for a symmetric matrix.
public struct SparseSymmetricMatrix: Sendable, Hashable {
    public let dimension: Int
    public let rowPointers: [Int]
    public let columnIndices: [Int]
    public let values: [Double]
    public init(dimension: Int, rowPointers: [Int], columnIndices: [Int],
                values: [Double]) throws {
        guard dimension > 0, rowPointers.count == dimension + 1,
              rowPointers.first == 0, rowPointers.last == values.count,
              columnIndices.count == values.count, values.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid sparse symmetric matrix")
        }
        for row in 0..<dimension {
            guard rowPointers[row] <= rowPointers[row + 1], rowPointers[row + 1] <= values.count else {
                throw NonlinearOptimizationError.invalidConfiguration("invalid sparse symmetric row pointers")
            }
            let columns = columnIndices[rowPointers[row]..<rowPointers[row + 1]]
            guard columns.allSatisfy({ $0 >= 0 && $0 <= row }),
                  zip(columns, columns.dropFirst()).allSatisfy({ $0 < $1 }) else {
                throw NonlinearOptimizationError.invalidConfiguration(
                    "sparse symmetric rows must be sorted unique lower triangles")
            }
        }
        self.dimension = dimension; self.rowPointers = rowPointers
        self.columnIndices = columnIndices; self.values = values
    }
    public var nonzeros: Int { values.count }
    public func multiplying(_ point: [Double]) throws -> [Double] {
        guard point.count == dimension else {
            throw NonlinearOptimizationError.invalidConfiguration("sparse Hessian dimension mismatch")
        }
        var result = [Double](repeating: 0, count: dimension)
        for row in 0..<dimension { for index in rowPointers[row]..<rowPointers[row + 1] {
            let column = columnIndices[index], value = values[index]
            result[row] += value * point[column]
            if column != row { result[column] += value * point[row] }
        }}
        return result
    }
    public func dense() -> [[Double]] {
        var result = [[Double]](repeating: [Double](repeating: 0, count: dimension), count: dimension)
        for row in 0..<dimension { for index in rowPointers[row]..<rowPointers[row + 1] {
            let column = columnIndices[index], value = values[index]
            result[row][column] = value; result[column][row] = value
        }}
        return result
    }
}

public struct SparseQuadraticProblem: Sendable, Hashable {
    public let quadratic: SparseSymmetricMatrix
    public let linear: [Double]
    public let constant: Double
    public let constraints: QuadraticConstraintMatrix
    public let rowBounds: [ParameterBound]
    public let variableBounds: [ParameterBound]
    public init(quadratic: SparseSymmetricMatrix, linear: [Double], constant: Double = 0,
                constraints: QuadraticConstraintMatrix, rowBounds: [ParameterBound],
                variableBounds: [ParameterBound]) {
        self.quadratic = quadratic; self.linear = linear; self.constant = constant
        self.constraints = constraints; self.rowBounds = rowBounds
        self.variableBounds = variableBounds
    }
    public func validate(convexityTolerance: Double = 1e-10) throws {
        try denseProblem.validate(convexityTolerance: convexityTolerance)
    }
    public func objective(at point: [Double]) throws -> Double {
        guard point.count == linear.count, point.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid sparse QP point")
        }
        return constant + zip(linear, point).reduce(0) { $0 + $1.0 * $1.1 }
            + 0.5 * zip(point, try quadratic.multiplying(point)).reduce(0) { $0 + $1.0 * $1.1 }
    }
    fileprivate var denseProblem: QuadraticProblem {
        .init(quadratic: quadratic.dense(), linear: linear, constant: constant,
              constraints: constraints, rowBounds: rowBounds, variableBounds: variableBounds)
    }
}

public extension ConvexQuadraticSolver {
    static func solve(_ problem: SparseQuadraticProblem, options: QuadraticOptions = .init(),
                      warmStart: QuadraticWarmStart? = nil,
                      observer: Observer? = nil) throws -> QuadraticResult {
        try problem.validate(convexityTolerance: options.convexityTolerance)
        return try solve(problem.denseProblem, options: options,
                         warmStart: warmStart, observer: observer)
    }
}

private func sparseMultiply(rows: Int, pointers: [Int], columns: [Int], values: [Double],
                            vector: [Double]) -> [Double] {
    var result = [Double](repeating: 0, count: rows)
    for row in 0..<rows { for index in pointers[row]..<pointers[row + 1] {
        result[row] += values[index] * vector[columns[index]]
    }}
    return result
}
private func sparseValidBound(_ bound: ParameterBound) -> Bool {
    (bound.lower?.isFinite ?? true) && (bound.upper?.isFinite ?? true)
        && (bound.lower ?? -.infinity) <= (bound.upper ?? .infinity)
}
