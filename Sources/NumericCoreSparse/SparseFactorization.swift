import Foundation
import NumericCore

/// Ordering used by reusable sparse factorizations. Minimum degree operates
/// on the symmetrized structural graph and is deterministic on ties.
public enum SparseOrdering: Sendable, Hashable {
    case natural
    case minimumDegree
}

public struct SparseNumericOptions: Sendable, Hashable {
    public var pivotTolerance: Double
    public var dropTolerance: Double
    public var refinementSteps: Int
    public var refinementTolerance: Double

    public init(
        pivotTolerance: Double = 1e-12,
        dropTolerance: Double = 0,
        refinementSteps: Int = 3,
        refinementTolerance: Double = 1e-12
    ) {
        self.pivotTolerance = pivotTolerance
        self.dropTolerance = dropTolerance
        self.refinementSteps = refinementSteps
        self.refinementTolerance = refinementTolerance
    }

    fileprivate func validate() throws {
        guard pivotTolerance.isFinite, pivotTolerance >= 0,
              dropTolerance.isFinite, dropTolerance >= 0,
              refinementSteps >= 0,
              refinementTolerance.isFinite, refinementTolerance >= 0 else {
            throw NCError.unsupportedOperation("Sparse factorization options must be finite and non-negative")
        }
    }
}

/// Structure-only analysis that can be reused while numerical values change.
public struct SparseSymbolicAnalysis: Sendable, Hashable {
    public let size: Int
    public let ordering: SparseOrdering
    /// Ordered index to original index.
    public let permutation: [Int]
    /// Original index to ordered index.
    public let inversePermutation: [Int]
    public let originalNonZeroCount: Int
    public let estimatedFactorNonZeroCount: Int
    fileprivate let pattern: [SparsePatternCoordinate]

    public init(matrix: SparseMatrix<Double>, ordering: SparseOrdering = .minimumDegree) throws {
        guard matrix.rows == matrix.cols else {
            throw NCError.dimensionMismatch("Sparse factorization requires a square matrix")
        }
        size = matrix.rows
        self.ordering = ordering
        originalNonZeroCount = matrix.nonZeroCount
        pattern = Self.pattern(of: matrix)
        var graph = [Set<Int>](repeating: [], count: size)
        for coordinate in pattern where coordinate.row != coordinate.column {
            graph[coordinate.row].insert(coordinate.column)
            graph[coordinate.column].insert(coordinate.row)
        }
        var active = [Bool](repeating: true, count: size)
        var result: [Int] = []
        var estimate = size
        for step in 0..<size {
            let vertex: Int
            switch ordering {
            case .natural:
                vertex = step
            case .minimumDegree:
                vertex = (0..<size).filter { active[$0] }.min {
                    let lhs = graph[$0].filter { active[$0] }.count
                    let rhs = graph[$1].filter { active[$0] }.count
                    return lhs == rhs ? $0 < $1 : lhs < rhs
                }!
            }
            let neighbors = graph[vertex].filter { active[$0] }.sorted()
            estimate += 2 * neighbors.count
            for i in neighbors.indices {
                for j in neighbors.index(after: i)..<neighbors.endIndex {
                    graph[neighbors[i]].insert(neighbors[j])
                    graph[neighbors[j]].insert(neighbors[i])
                }
                graph[neighbors[i]].remove(vertex)
            }
            active[vertex] = false
            result.append(vertex)
        }
        permutation = result
        var inverse = [Int](repeating: 0, count: size)
        for (ordered, original) in result.enumerated() { inverse[original] = ordered }
        inversePermutation = inverse
        estimatedFactorNonZeroCount = estimate
    }

    fileprivate func validate(_ matrix: SparseMatrix<Double>) throws {
        guard matrix.rows == size, matrix.cols == size, Self.pattern(of: matrix) == pattern else {
            throw NCError.dimensionMismatch("Matrix sparsity pattern does not match the symbolic analysis")
        }
    }

    private static func pattern(of matrix: SparseMatrix<Double>) -> [SparsePatternCoordinate] {
        var result: [SparsePatternCoordinate] = []
        result.reserveCapacity(matrix.nonZeroCount)
        for row in 0..<matrix.rows {
            for index in matrix.csrRowPointers[row]..<matrix.csrRowPointers[row + 1] {
                result.append(.init(row: row, column: matrix.csrColumnIndices[index]))
            }
        }
        return result
    }
}

private struct SparsePatternCoordinate: Sendable, Hashable {
    let row: Int
    let column: Int
}

public struct SparseFactorizationDiagnostics: Sendable, Hashable {
    public let ordering: SparseOrdering
    public let originalNonZeroCount: Int
    public let factorNonZeroCount: Int
    public let estimatedFactorNonZeroCount: Int
    public let fillRatio: Double
    public let minimumAbsolutePivot: Double
    public let pivotGrowth: Double
    public let interchangeCount: Int
}

public struct SparseRefinedResult: Sendable, Hashable {
    public let solution: [Double]
    public let residualNorm: Double
    public let relativeResidual: Double
    public let backwardError: Double
    public let refinementSteps: Int
    public let diagnostics: SparseFactorizationDiagnostics
}

/// Reusable pivoted sparse LU. Symbolic ordering is separated from numeric
/// factorization so sequences with an unchanged pattern avoid reanalysis.
public final class SparseLUFactorization {
    public let symbolicAnalysis: SparseSymbolicAnalysis
    public let options: SparseNumericOptions
    public private(set) var diagnostics: SparseFactorizationDiagnostics
    private var factors: [[Int: Double]]
    private var rowPermutation: [Int]
    private var matrix: SparseMatrix<Double>

    public convenience init(
        matrix: SparseMatrix<Double>, ordering: SparseOrdering = .minimumDegree,
        options: SparseNumericOptions = .init()
    ) throws {
        try self.init(matrix: matrix, analysis: SparseSymbolicAnalysis(matrix: matrix, ordering: ordering), options: options)
    }

    public init(
        matrix: SparseMatrix<Double>, analysis: SparseSymbolicAnalysis,
        options: SparseNumericOptions = .init()
    ) throws {
        try options.validate(); try analysis.validate(matrix)
        symbolicAnalysis = analysis; self.options = options; self.matrix = matrix
        let numeric = try Self.factor(matrix, analysis: analysis, options: options)
        factors = numeric.rows; rowPermutation = numeric.permutation; diagnostics = numeric.diagnostics
    }

    public func refactor(with matrix: SparseMatrix<Double>) throws {
        try symbolicAnalysis.validate(matrix)
        let numeric = try Self.factor(matrix, analysis: symbolicAnalysis, options: options)
        factors = numeric.rows; rowPermutation = numeric.permutation
        diagnostics = numeric.diagnostics; self.matrix = matrix
    }

    public func solve(_ rhs: [Double]) throws -> [Double] {
        try validate(rhs: rhs, size: symbolicAnalysis.size)
        var x = symbolicAnalysis.permutation.map { rhs[$0] }
        x = rowPermutation.map { x[$0] }
        for row in x.indices {
            x[row] -= factors[row].filter { $0.key < row }.reduce(0) { $0 + $1.value * x[$1.key] }
        }
        for row in x.indices.reversed() {
            let diagonal = factors[row][row] ?? 0
            guard abs(diagonal) > options.pivotTolerance else { throw singular(row) }
            let contribution = factors[row].filter { $0.key > row }.reduce(0) { $0 + $1.value * x[$1.key] }
            x[row] = (x[row] - contribution) / diagonal
        }
        var solution = [Double](repeating: 0, count: x.count)
        for (ordered, original) in symbolicAnalysis.permutation.enumerated() { solution[original] = x[ordered] }
        return solution
    }

    public func solve(_ rightHandSides: [[Double]]) throws -> [[Double]] { try rightHandSides.map(solve) }

    public func solveRefined(_ rhs: [Double]) throws -> SparseRefinedResult {
        var solution = try solve(rhs); var steps = 0
        for _ in 0..<options.refinementSteps {
            let r = residual(matrix, rhs: rhs, solution: solution)
            if backwardError(matrix, rhs: rhs, solution: solution, residual: r) <= options.refinementTolerance { break }
            let correction = try solve(r)
            for index in solution.indices { solution[index] += correction[index] }
            steps += 1
        }
        return report(matrix, rhs: rhs, solution: solution, steps: steps, diagnostics: diagnostics)
    }

    private static func factor(
        _ matrix: SparseMatrix<Double>, analysis: SparseSymbolicAnalysis, options: SparseNumericOptions
    ) throws -> (rows: [[Int: Double]], permutation: [Int], diagnostics: SparseFactorizationDiagnostics) {
        let source = try sparseRows(matrix)
        var rows = [[Int: Double]](repeating: [:], count: source.count)
        var maximumInput = 0.0
        for originalRow in source.indices {
            let row = analysis.inversePermutation[originalRow]
            for (originalColumn, value) in source[originalRow] {
                rows[row][analysis.inversePermutation[originalColumn]] = value
                maximumInput = max(maximumInput, abs(value))
            }
        }
        var permutation = Array(rows.indices); var interchanges = 0; var minimumPivot = Double.infinity
        for pivot in rows.indices {
            let selected = (pivot..<rows.count).max { abs(rows[$0][pivot] ?? 0) < abs(rows[$1][pivot] ?? 0) }!
            guard abs(rows[selected][pivot] ?? 0) > options.pivotTolerance * max(maximumInput, 1) else { throw singular(pivot) }
            if selected != pivot { rows.swapAt(selected, pivot); permutation.swapAt(selected, pivot); interchanges += 1 }
            let diagonal = rows[pivot][pivot]!; minimumPivot = min(minimumPivot, abs(diagonal))
            let upper = rows[pivot].filter { $0.key > pivot }
            if pivot + 1 < rows.count {
                for row in pivot + 1..<rows.count {
                    let entry = rows[row][pivot] ?? 0
                    if entry == 0 { continue }
                    let multiplier = entry / diagonal; rows[row][pivot] = multiplier
                    for (column, value) in upper {
                        let updated = (rows[row][column] ?? 0) - multiplier * value
                        guard updated.isFinite else { throw invalidNumeric() }
                        if abs(updated) <= options.dropTolerance { rows[row].removeValue(forKey: column) }
                        else { rows[row][column] = updated }
                    }
                }
            }
        }
        let nnz = rows.reduce(0) { $0 + $1.count }
        let maxFactor = rows.flatMap(\.values).reduce(0) { max($0, abs($1)) }
        return (rows, permutation, makeDiagnostics(analysis, nnz: nnz, pivot: minimumPivot,
                                                    growth: maxFactor / max(maximumInput, .leastNonzeroMagnitude), swaps: interchanges))
    }
}

public struct SparseInertia: Sendable, Hashable {
    public let positive: Int
    public let negative: Int
    public let zero: Int
    public init(positive: Int, negative: Int, zero: Int) {
        self.positive = positive; self.negative = negative; self.zero = zero
    }
}

private enum DiagonalBlock {
    case one(index: Int, value: Double)
    case two(index: Int, a: Double, b: Double, c: Double)
}

/// Symmetric-indefinite sparse LDLᵀ with 1×1/2×2 complete pivots. Inertia is
/// exposed for KKT-system convergence and second-order tests.
public final class SparseLDLTFactorization {
    public let symbolicAnalysis: SparseSymbolicAnalysis
    public let options: SparseNumericOptions
    public private(set) var diagnostics: SparseFactorizationDiagnostics
    public private(set) var inertia: SparseInertia
    private var lower: [[Int: Double]]
    private var blocks: [DiagonalBlock]
    private var numericPermutation: [Int]
    private var matrix: SparseMatrix<Double>

    public convenience init(matrix: SparseMatrix<Double>, ordering: SparseOrdering = .minimumDegree,
                            options: SparseNumericOptions = .init()) throws {
        try self.init(matrix: matrix, analysis: SparseSymbolicAnalysis(matrix: matrix, ordering: ordering), options: options)
    }

    public init(matrix: SparseMatrix<Double>, analysis: SparseSymbolicAnalysis,
                options: SparseNumericOptions = .init()) throws {
        try options.validate(); try analysis.validate(matrix)
        symbolicAnalysis = analysis; self.options = options; self.matrix = matrix
        let numeric = try Self.factor(matrix, analysis: analysis, options: options)
        lower = numeric.lower; blocks = numeric.blocks; numericPermutation = numeric.permutation
        diagnostics = numeric.diagnostics; inertia = numeric.inertia
    }

    public func refactor(with matrix: SparseMatrix<Double>) throws {
        try symbolicAnalysis.validate(matrix)
        let numeric = try Self.factor(matrix, analysis: symbolicAnalysis, options: options)
        lower = numeric.lower; blocks = numeric.blocks; numericPermutation = numeric.permutation
        diagnostics = numeric.diagnostics; inertia = numeric.inertia; self.matrix = matrix
    }

    public func solve(_ rhs: [Double]) throws -> [Double] {
        try validate(rhs: rhs, size: symbolicAnalysis.size)
        let ordered = symbolicAnalysis.permutation.map { rhs[$0] }
        var x = numericPermutation.map { ordered[$0] }
        for row in x.indices { x[row] -= lower[row].filter { $0.key < row }.reduce(0) { $0 + $1.value * x[$1.key] } }
        for block in blocks {
            switch block {
            case .one(let index, let value): x[index] /= value
            case .two(let index, let a, let b, let c):
                let determinant = a * c - b * b, first = x[index], second = x[index + 1]
                x[index] = (c * first - b * second) / determinant
                x[index + 1] = (-b * first + a * second) / determinant
            }
        }
        for row in x.indices.reversed() {
            var contribution = 0.0
            if row + 1 < x.count { for source in row + 1..<x.count { contribution += (lower[source][row] ?? 0) * x[source] } }
            x[row] -= contribution
        }
        var afterNumeric = [Double](repeating: 0, count: x.count)
        for (index, previous) in numericPermutation.enumerated() { afterNumeric[previous] = x[index] }
        var solution = [Double](repeating: 0, count: x.count)
        for (index, original) in symbolicAnalysis.permutation.enumerated() { solution[original] = afterNumeric[index] }
        return solution
    }

    public func solve(_ rightHandSides: [[Double]]) throws -> [[Double]] { try rightHandSides.map(solve) }

    public func solveRefined(_ rhs: [Double]) throws -> SparseRefinedResult {
        var solution = try solve(rhs); var steps = 0
        for _ in 0..<options.refinementSteps {
            let r = residual(matrix, rhs: rhs, solution: solution)
            if backwardError(matrix, rhs: rhs, solution: solution, residual: r) <= options.refinementTolerance { break }
            let correction = try solve(r); for index in solution.indices { solution[index] += correction[index] }; steps += 1
        }
        return report(matrix, rhs: rhs, solution: solution, steps: steps, diagnostics: diagnostics)
    }

    private static func factor(_ matrix: SparseMatrix<Double>, analysis: SparseSymbolicAnalysis,
                               options: SparseNumericOptions) throws
    -> (lower: [[Int: Double]], blocks: [DiagonalBlock], permutation: [Int],
        diagnostics: SparseFactorizationDiagnostics, inertia: SparseInertia) {
        let source = try sparseRows(matrix); try checkSymmetric(source)
        let n = source.count; var active = [[Int: Double]](repeating: [:], count: n); var maximumInput = 0.0
        for originalRow in source.indices { let row = analysis.inversePermutation[originalRow]
            for (originalColumn, value) in source[originalRow] { active[row][analysis.inversePermutation[originalColumn]] = value; maximumInput = max(maximumInput, abs(value)) }
        }
        var lower = [[Int: Double]](repeating: [:], count: n); for i in 0..<n { lower[i][i] = 1 }
        var permutation = Array(0..<n), blocks: [DiagonalBlock] = []; var k = 0, swaps = 0; var minimumPivot = Double.infinity
        let threshold = options.pivotTolerance * max(maximumInput, 1)
        while k < n {
            var bestDiagonal = (index: k, value: 0.0), bestOff = (first: k, second: k, value: 0.0)
            for i in k..<n { let diagonal = abs(active[i][i] ?? 0); if diagonal > bestDiagonal.value { bestDiagonal = (i, diagonal) }
                if i + 1 < n { for j in i + 1..<n { let value = abs(active[i][j] ?? 0); if value > bestOff.value { bestOff = (i, j, value) } } }
            }
            guard bestDiagonal.value > threshold || bestOff.value > threshold else { throw singular(k) }
            if k + 1 == n || bestDiagonal.value >= bestOff.value {
                if bestDiagonal.index != k { symmetricSwap(&active, lower: &lower, permutation: &permutation, k, bestDiagonal.index, completed: k); swaps += 1 }
                let d = active[k][k] ?? 0; minimumPivot = min(minimumPivot, abs(d))
                if k + 1 < n {
                    for i in k + 1..<n { let value = (active[i][k] ?? 0) / d; if abs(value) > options.dropTolerance { lower[i][k] = value } }
                    for i in k + 1..<n { for j in i..<n { try updateSymmetric(&active, i, j, delta: -(lower[i][k] ?? 0) * d * (lower[j][k] ?? 0), drop: options.dropTolerance) } }
                }
                blocks.append(.one(index: k, value: d)); k += 1
            } else {
                let first = bestOff.first, second = bestOff.second
                if first != k { symmetricSwap(&active, lower: &lower, permutation: &permutation, k, first, completed: k); swaps += 1 }
                let relocatedSecond = second == k ? first : (second == first ? k : second)
                if relocatedSecond != k + 1 { symmetricSwap(&active, lower: &lower, permutation: &permutation, k + 1, relocatedSecond, completed: k); swaps += 1 }
                let a = active[k][k] ?? 0, b = active[k][k + 1] ?? 0, c = active[k + 1][k + 1] ?? 0, determinant = a * c - b * b
                guard abs(determinant) > threshold * threshold else { throw singular(k) }; minimumPivot = min(minimumPivot, sqrt(abs(determinant)))
                if k + 2 < n {
                    for i in k + 2..<n { let r1 = active[i][k] ?? 0, r2 = active[i][k + 1] ?? 0
                        let l1 = (c * r1 - b * r2) / determinant, l2 = (-b * r1 + a * r2) / determinant
                        if abs(l1) > options.dropTolerance { lower[i][k] = l1 }; if abs(l2) > options.dropTolerance { lower[i][k + 1] = l2 }
                    }
                    for i in k + 2..<n { for j in i..<n { let i1 = lower[i][k] ?? 0, i2 = lower[i][k + 1] ?? 0, j1 = lower[j][k] ?? 0, j2 = lower[j][k + 1] ?? 0
                        try updateSymmetric(&active, i, j, delta: -(i1 * (a * j1 + b * j2) + i2 * (b * j1 + c * j2)), drop: options.dropTolerance) } }
                }
                blocks.append(.two(index: k, a: a, b: b, c: c)); k += 2
            }
        }
        let inertia = blockInertia(blocks, tolerance: threshold)
        let nnz = lower.reduce(0) { $0 + $1.count } + blocks.reduce(0) { $0 + ($1.isOne ? 1 : 3) }
        let maxLower = lower.flatMap(\.values).reduce(0) { max($0, abs($1)) }
        let maxDiagonal = blocks.reduce(0.0) { maximum, block in
            switch block {
            case .one(_, let value): return max(maximum, abs(value))
            case .two(_, let a, let b, let c): return max(maximum, abs(a), abs(b), abs(c))
            }
        }
        let maxFactor = max(maxLower, maxDiagonal)
        return (lower, blocks, permutation, makeDiagnostics(analysis, nnz: nnz, pivot: minimumPivot,
                                                             growth: maxFactor / max(maximumInput, .leastNonzeroMagnitude), swaps: swaps), inertia)
    }
}

private extension DiagonalBlock { var isOne: Bool { if case .one = self { return true }; return false } }
private func sparseRows(_ matrix: SparseMatrix<Double>) throws -> [[Int: Double]] { guard matrix.rows == matrix.cols else { throw NCError.dimensionMismatch("Sparse factorization requires a square matrix") }; var rows = [[Int: Double]](repeating: [:], count: matrix.rows); for row in 0..<matrix.rows { for index in matrix.csrRowPointers[row]..<matrix.csrRowPointers[row + 1] { let value = matrix.csrValues[index]; guard value.isFinite else { throw invalidNumeric() }; rows[row][matrix.csrColumnIndices[index], default: 0] += value } }; return rows }
private func checkSymmetric(_ rows: [[Int: Double]]) throws { for row in rows.indices { for (column, value) in rows[row] { let reverse = rows[column][row] ?? 0; guard abs(value - reverse) <= 1e-12 * max(abs(value), abs(reverse), 1) else { throw NCError.unsupportedOperation("Matrix is not symmetric at (\(row), \(column))") } } } }
private func symmetricSwap(_ matrix: inout [[Int: Double]], lower: inout [[Int: Double]], permutation: inout [Int], _ a: Int, _ b: Int, completed: Int) { guard a != b else { return }; let n = matrix.count; func mapped(_ i: Int) -> Int { i == a ? b : (i == b ? a : i) }; let old = matrix; matrix = [[Int: Double]](repeating: [:], count: n); for row in old.indices { for (column, value) in old[row] { matrix[mapped(row)][mapped(column)] = value } }; for column in 0..<completed { let av = lower[a].removeValue(forKey: column), bv = lower[b].removeValue(forKey: column); lower[a][column] = bv; lower[b][column] = av }; permutation.swapAt(a, b) }
private func updateSymmetric(_ matrix: inout [[Int: Double]], _ row: Int, _ column: Int, delta: Double, drop: Double) throws { let value = (matrix[row][column] ?? 0) + delta; guard value.isFinite else { throw invalidNumeric() }; if abs(value) <= drop { matrix[row].removeValue(forKey: column); matrix[column].removeValue(forKey: row) } else { matrix[row][column] = value; matrix[column][row] = value } }
private func blockInertia(_ blocks: [DiagonalBlock], tolerance: Double) -> SparseInertia { var positive = 0, negative = 0, zero = 0; func count(_ value: Double) { if value > tolerance { positive += 1 } else if value < -tolerance { negative += 1 } else { zero += 1 } }; for block in blocks { switch block { case .one(_, let value): count(value); case .two(_, let a, let b, let c): let middle = 0.5 * (a + c), radius = sqrt(0.25 * pow(a - c, 2) + b * b); count(middle + radius); count(middle - radius) } }; return .init(positive: positive, negative: negative, zero: zero) }
private func validate(rhs: [Double], size: Int) throws { guard rhs.count == size else { throw NCError.dimensionMismatch("Right-hand side has \(rhs.count) entries, expected \(size)") }; guard rhs.allSatisfy(\.isFinite) else { throw invalidNumeric() } }
private func residual(_ matrix: SparseMatrix<Double>, rhs: [Double], solution: [Double]) -> [Double] { var result = rhs; for row in 0..<matrix.rows { for index in matrix.csrRowPointers[row]..<matrix.csrRowPointers[row + 1] { result[row] -= matrix.csrValues[index] * solution[matrix.csrColumnIndices[index]] } }; return result }
private func backwardError(_ matrix: SparseMatrix<Double>, rhs: [Double], solution: [Double], residual: [Double]) -> Double { var rowSums = [Double](repeating: 0, count: matrix.rows); for row in 0..<matrix.rows { for index in matrix.csrRowPointers[row]..<matrix.csrRowPointers[row + 1] { rowSums[row] += abs(matrix.csrValues[index]) } }; let denominator = (rowSums.max() ?? 0) * (solution.map(abs).max() ?? 0) + (rhs.map(abs).max() ?? 0); return (residual.map(abs).max() ?? 0) / max(denominator, .leastNonzeroMagnitude) }
private func report(_ matrix: SparseMatrix<Double>, rhs: [Double], solution: [Double], steps: Int, diagnostics: SparseFactorizationDiagnostics) -> SparseRefinedResult { let r = residual(matrix, rhs: rhs, solution: solution), norm = sqrt(r.reduce(0) { $0 + $1 * $1 }), rhsNorm = sqrt(rhs.reduce(0) { $0 + $1 * $1 }); return .init(solution: solution, residualNorm: norm, relativeResidual: norm / max(rhsNorm, .leastNonzeroMagnitude), backwardError: backwardError(matrix, rhs: rhs, solution: solution, residual: r), refinementSteps: steps, diagnostics: diagnostics) }
private func makeDiagnostics(_ analysis: SparseSymbolicAnalysis, nnz: Int, pivot: Double, growth: Double, swaps: Int) -> SparseFactorizationDiagnostics { .init(ordering: analysis.ordering, originalNonZeroCount: analysis.originalNonZeroCount, factorNonZeroCount: nnz, estimatedFactorNonZeroCount: analysis.estimatedFactorNonZeroCount, fillRatio: Double(nnz) / Double(max(analysis.originalNonZeroCount, 1)), minimumAbsolutePivot: pivot, pivotGrowth: growth, interchangeCount: swaps) }
private func singular(_ pivot: Int) -> NCError { .unsupportedOperation("Matrix is singular at pivot \(pivot)") }
private func invalidNumeric() -> NCError { .unsupportedOperation("Sparse matrix and right-hand side must contain only finite values") }
