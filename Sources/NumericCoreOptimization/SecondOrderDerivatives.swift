import Foundation
import NumericCoreSparse

public struct SecondOrderValue: Sendable, Hashable {
    public let value: Double
    public let gradient: [Double]
    public let hessian: [[Double]]
}

public struct SparseHessian: Sendable, Hashable {
    public let dimension: Int
    public let rowPointers: [Int]
    public let columnIndices: [Int]
    public let values: [Double]

    public init(dimension: Int, rowPointers: [Int], columnIndices: [Int], values: [Double]) {
        self.dimension = dimension; self.rowPointers = rowPointers
        self.columnIndices = columnIndices; self.values = values
    }

    public func multiplying(_ direction: [Double]) throws -> [Double] {
        guard direction.count == dimension else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "Hessian direction dimension does not agree")
        }
        var result = [Double](repeating: 0, count: dimension)
        for row in 0..<dimension {
            for entry in rowPointers[row]..<rowPointers[row + 1] {
                result[row] += values[entry] * direction[columnIndices[entry]]
            }
        }
        return result
    }
}

public extension NonlinearExpression {
    func evaluateSecondOrder(parameters: [Double]) throws -> SecondOrderValue {
        try validate(parameterCount: parameters.count)
        guard parameters.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        let n = parameters.count
        var values: [Double] = [], gradients: [[Double]] = [], hessians: [[[Double]]] = []
        for node in nodes {
            let result = secondOrderNode(node, parameters, values, gradients, hessians, n)
            guard result.0.isFinite, result.1.allSatisfy(\.isFinite),
                  result.2.joined().allSatisfy(\.isFinite) else {
                throw NonlinearOptimizationError.invalidEvaluation(
                    "second-order evaluation produced a non-finite value")
            }
            values.append(result.0); gradients.append(result.1); hessians.append(result.2)
        }
        return .init(value: values[output], gradient: gradients[output],
                     hessian: hessians[output])
    }

    func hessianVectorProduct(parameters: [Double], direction: [Double]) throws -> [Double] {
        guard parameters.count == direction.count, direction.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "Hessian direction must be finite and match the parameter dimension")
        }
        return secondMatvec(try evaluateSecondOrder(parameters: parameters).hessian, direction)
    }

    func evaluateSparseHessian(parameters: [Double], zeroTolerance: Double = 0) throws
        -> (value: Double, gradient: [Double], hessian: SparseHessian) {
        guard zeroTolerance.isFinite, zeroTolerance >= 0 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid Hessian zero tolerance")
        }
        let result = try evaluateSecondOrder(parameters: parameters)
        var rowPointers = [0], columns: [Int] = [], values: [Double] = []
        for row in result.hessian {
            for (column, value) in row.enumerated() where abs(value) > zeroTolerance {
                columns.append(column); values.append(value)
            }
            rowPointers.append(values.count)
        }
        return (result.value, result.gradient, .init(
            dimension: parameters.count, rowPointers: rowPointers,
            columnIndices: columns, values: values))
    }
}

public extension ConstrainedNonlinearProblem {
    func lagrangianHessian(parameters: [Double], constraintWeights: [Double]) throws
        -> [[Double]] {
        guard constraintWeights.count == constraints.count,
              constraintWeights.allSatisfy(\.isFinite), let objective = model.objective else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "Lagrangian weights must be finite and match the constraint count")
        }
        var result = try objective.evaluateSecondOrder(parameters: parameters).hessian
        for (constraint, weight) in zip(constraints, constraintWeights) where weight != 0 {
            let hessian = try constraint.expression.evaluateSecondOrder(parameters: parameters).hessian
            secondAddScaled(&result, hessian, weight)
        }
        return result
    }

    func lagrangianHessianVectorProduct(parameters: [Double],
                                        constraintWeights: [Double], direction: [Double]) throws
        -> [Double] {
        guard direction.count == model.parameterCount else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "Lagrangian Hessian direction dimension does not agree")
        }
        return secondMatvec(try lagrangianHessian(
            parameters: parameters, constraintWeights: constraintWeights), direction)
    }

    /// Assemble exact graph derivatives directly into the reusable sparse KKT contract.
    func linearizeSparseKKT(parameters: [Double], constraintWeights: [Double],
                            primalRightHandSide: [Double], constraintRightHandSide: [Double],
                            primalRegularization: Double = 0,
                            dualRegularization: Double = 0,
                            zeroTolerance: Double = 0) throws -> SparseKKTProblem {
        guard primalRightHandSide.count == model.parameterCount,
              constraintRightHandSide.count == constraints.count,
              zeroTolerance.isFinite, zeroTolerance >= 0 else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "invalid sparse KKT linearization dimensions or tolerance")
        }
        let dense = try lagrangianHessian(
            parameters: parameters, constraintWeights: constraintWeights)
        var hessianPointers = [0], hessianColumns: [Int] = [], hessianValues: [Double] = []
        for row in dense {
            for (column, value) in row.enumerated() where abs(value) > zeroTolerance {
                hessianColumns.append(column); hessianValues.append(value)
            }
            hessianPointers.append(hessianValues.count)
        }
        var pointers = [0], columns: [Int] = [], values: [Double] = []
        for constraint in constraints {
            let derivative = try constraint.expression.evaluateSparse(parameters: parameters).derivative
            columns += derivative.indices; values += derivative.values; pointers.append(values.count)
        }
        return .init(hessian: .init(dimension: model.parameterCount,
                                    rowPointers: hessianPointers,
                                    columnIndices: hessianColumns, values: hessianValues),
                     jacobian: .init(rows: constraints.count, columns: model.parameterCount,
                                     rowPointers: pointers, columnIndices: columns, values: values),
                     primalRightHandSide: primalRightHandSide,
                     constraintRightHandSide: constraintRightHandSide,
                     primalRegularization: primalRegularization,
                     dualRegularization: dualRegularization)
    }
}

public struct SparseKKTProblem: Sendable, Hashable {
    public let hessian: SparseHessian
    public let jacobian: SparseJacobian
    public let primalRightHandSide: [Double]
    public let constraintRightHandSide: [Double]
    public let primalRegularization: Double
    public let dualRegularization: Double

    public init(hessian: SparseHessian, jacobian: SparseJacobian,
                primalRightHandSide: [Double], constraintRightHandSide: [Double],
                primalRegularization: Double = 0, dualRegularization: Double = 0) {
        self.hessian = hessian; self.jacobian = jacobian
        self.primalRightHandSide = primalRightHandSide
        self.constraintRightHandSide = constraintRightHandSide
        self.primalRegularization = primalRegularization
        self.dualRegularization = dualRegularization
    }
}

public struct SparseKKTResult: Sendable, Hashable {
    public let primal: [Double]
    public let dual: [Double]
    public let residualNorm: Double
    public let relativeResidual: Double
    public let factorNonzeros: Int
    public let symbolicAnalyses: Int
    public let numericFactorizations: Int
    public let solves: Int
    public let symbolicReused: Bool
    public let inertia: SparseInertia?

    public init(primal: [Double], dual: [Double], residualNorm: Double,
                relativeResidual: Double, factorNonzeros: Int,
                symbolicAnalyses: Int = 1, numericFactorizations: Int = 1,
                solves: Int = 1, symbolicReused: Bool = false,
                inertia: SparseInertia? = nil) {
        self.primal = primal; self.dual = dual
        self.residualNorm = residualNorm; self.relativeResidual = relativeResidual
        self.factorNonzeros = factorNonzeros
        self.symbolicAnalyses = symbolicAnalyses
        self.numericFactorizations = numericFactorizations
        self.solves = solves; self.symbolicReused = symbolicReused; self.inertia = inertia
    }
}

/// One-shot compatibility entry point over the reusable sparse KKT pipeline.
public enum SparseKKTSolver {
    public static func solve(_ problem: SparseKKTProblem) throws -> SparseKKTResult {
        let workspace = try SparseKKTWorkspace(problem: problem)
        return try workspace.solve(problem)
    }
}

/// Reuses symbolic ordering across a sequence of nonlinear KKT systems with
/// unchanged Hessian/Jacobian structure, while refactorizing numeric values.
public final class SparseKKTWorkspace {
    public let symbolicAnalysis: SparseSymbolicAnalysis
    public private(set) var symbolicAnalysisCount = 1
    public private(set) var numericFactorizationCount = 0
    public private(set) var solveCount = 0
    private let primalDimension: Int
    private let constraintDimension: Int
    private let options: SparseNumericOptions
    private var factorization: SparseLDLTFactorization?

    public init(problem: SparseKKTProblem, ordering: SparseOrdering = .minimumDegree,
                options: SparseNumericOptions = .init()) throws {
        let matrix = try Self.assemble(problem)
        primalDimension = problem.hessian.dimension
        constraintDimension = problem.jacobian.rows
        self.options = options
        symbolicAnalysis = try SparseSymbolicAnalysis(matrix: matrix, ordering: ordering)
    }

    public func solve(_ problem: SparseKKTProblem) throws -> SparseKKTResult {
        guard problem.hessian.dimension == primalDimension,
              problem.jacobian.rows == constraintDimension else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "sparse KKT workspace dimensions changed")
        }
        let matrix = try Self.assemble(problem)
        let reused = factorization != nil
        if let factorization {
            try factorization.refactor(with: matrix)
        } else {
            factorization = try SparseLDLTFactorization(
                matrix: matrix, analysis: symbolicAnalysis, options: options)
        }
        numericFactorizationCount += 1
        let rhs = problem.primalRightHandSide + problem.constraintRightHandSide
        let report = try factorization!.solveRefined(rhs)
        solveCount += 1
        return .init(primal: Array(report.solution.prefix(primalDimension)),
                     dual: Array(report.solution.dropFirst(primalDimension)),
                     residualNorm: report.residualNorm,
                     relativeResidual: report.relativeResidual,
                     factorNonzeros: report.diagnostics.factorNonZeroCount,
                     symbolicAnalyses: symbolicAnalysisCount,
                     numericFactorizations: numericFactorizationCount,
                     solves: solveCount, symbolicReused: reused,
                     inertia: factorization!.inertia)
    }

    private static func assemble(_ problem: SparseKKTProblem) throws -> SparseMatrix<Double> {
        let n = problem.hessian.dimension, m = problem.jacobian.rows, size = n + m
        guard problem.jacobian.columns == n, problem.primalRightHandSide.count == n,
              problem.constraintRightHandSide.count == m,
              problem.primalRegularization.isFinite, problem.primalRegularization >= 0,
              problem.dualRegularization.isFinite, problem.dualRegularization >= 0 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid sparse KKT problem")
        }
        var entries: [SparseEntry<Double>] = []
        entries.reserveCapacity(problem.hessian.values.count + 2 * problem.jacobian.values.count + size)
        for row in 0..<n {
            for entry in problem.hessian.rowPointers[row]..<problem.hessian.rowPointers[row + 1] {
                entries.append(.init(row: row, column: problem.hessian.columnIndices[entry],
                                     value: problem.hessian.values[entry]))
            }
            if problem.primalRegularization != 0 {
                entries.append(.init(row: row, column: row, value: problem.primalRegularization))
            }
        }
        for row in 0..<m {
            for entry in problem.jacobian.rowPointers[row]..<problem.jacobian.rowPointers[row + 1] {
                let column = problem.jacobian.columnIndices[entry], value = problem.jacobian.values[entry]
                entries.append(.init(row: n + row, column: column, value: value))
                entries.append(.init(row: column, column: n + row, value: value))
            }
            if problem.dualRegularization != 0 {
                entries.append(.init(row: n + row, column: n + row,
                                     value: -problem.dualRegularization))
            }
        }
        return try SparseMatrix(rows: size, cols: size, entries: entries)
    }
}

private func secondOrderNode(_ node: NonlinearNode, _ parameters: [Double], _ values: [Double],
                             _ gradients: [[Double]], _ hessians: [[[Double]]], _ n: Int)
    -> (Double, [Double], [[Double]]) {
    switch node {
    case .constant(let value): return (value, [Double](repeating: 0, count: n), secondZeros(n))
    case .parameter(let index):
        var gradient = [Double](repeating: 0, count: n); gradient[index] = 1
        return (parameters[index], gradient, secondZeros(n))
    case .add(let a, let b): return secondLinear(a, b, 1, values, gradients, hessians)
    case .subtract(let a, let b): return secondLinear(a, b, -1, values, gradients, hessians)
    case .multiply(let a, let b):
        return secondBinary(a, b, values[a] * values[b], values[b], values[a], 0, 1, 0,
                            gradients, hessians)
    case .divide(let a, let b):
        return secondBinary(a, b, values[a] / values[b], 1 / values[b],
                            -values[a] / pow(values[b], 2), 0, -1 / pow(values[b], 2),
                            2 * values[a] / pow(values[b], 3), gradients, hessians)
    case .negate(let a): return secondUnary(a, -values[a], -1, 0, gradients, hessians)
    case .exp(let a): let value = exp(values[a]); return secondUnary(a, value, value, value, gradients, hessians)
    case .log(let a): return secondUnary(a, log(values[a]), 1 / values[a], -1 / pow(values[a], 2), gradients, hessians)
    case .sqrt(let a): let value = sqrt(values[a]); return secondUnary(a, value, 0.5 / value, -0.25 / (values[a] * value), gradients, hessians)
    case .sin(let a): return secondUnary(a, sin(values[a]), cos(values[a]), -sin(values[a]), gradients, hessians)
    case .cos(let a): return secondUnary(a, cos(values[a]), -sin(values[a]), -cos(values[a]), gradients, hessians)
    case .pow(let a, let p): return secondUnary(a, pow(values[a], p), p * pow(values[a], p - 1), p * (p - 1) * pow(values[a], p - 2), gradients, hessians)
    }
}
private func secondLinear(_ a: Int, _ b: Int, _ sign: Double, _ values: [Double],
                          _ gradients: [[Double]], _ hessians: [[[Double]]])
    -> (Double, [Double], [[Double]]) {
    let gradient = zip(gradients[a], gradients[b]).map { $0 + sign * $1 }
    var hessian = hessians[a]; secondAddScaled(&hessian, hessians[b], sign)
    return (values[a] + sign * values[b], gradient, hessian)
}
private func secondUnary(_ a: Int, _ value: Double, _ first: Double, _ second: Double,
                         _ gradients: [[Double]], _ hessians: [[[Double]]])
    -> (Double, [Double], [[Double]]) {
    let gradient = gradients[a].map { first * $0 }
    var hessian = hessians[a].map { $0.map { first * $0 } }
    secondOuter(&hessian, gradients[a], gradients[a], second)
    return (value, gradient, hessian)
}
private func secondBinary(_ a: Int, _ b: Int, _ value: Double, _ fa: Double, _ fb: Double,
                          _ faa: Double, _ fab: Double, _ fbb: Double,
                          _ gradients: [[Double]], _ hessians: [[[Double]]])
    -> (Double, [Double], [[Double]]) {
    let gradient = zip(gradients[a], gradients[b]).map { fa * $0 + fb * $1 }
    var hessian = hessians[a].map { $0.map { fa * $0 } }; secondAddScaled(&hessian, hessians[b], fb)
    secondOuter(&hessian, gradients[a], gradients[a], faa)
    secondOuter(&hessian, gradients[a], gradients[b], fab)
    secondOuter(&hessian, gradients[b], gradients[a], fab)
    secondOuter(&hessian, gradients[b], gradients[b], fbb)
    return (value, gradient, hessian)
}
private func secondZeros(_ n: Int) -> [[Double]] { [[Double]](repeating: [Double](repeating: 0, count: n), count: n) }
private func secondAddScaled(_ target: inout [[Double]], _ source: [[Double]], _ scale: Double) {
    for i in target.indices { for j in target[i].indices { target[i][j] += scale * source[i][j] } }
}
private func secondOuter(_ target: inout [[Double]], _ left: [Double], _ right: [Double], _ scale: Double) {
    for i in left.indices { for j in right.indices { target[i][j] += scale * left[i] * right[j] } }
}
private func secondMatvec(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
    matrix.map { zip($0, vector).reduce(0) { $0 + $1.0 * $1.1 } }
}
private func secondDenseSolve(_ input: [[Double]], _ rhs: [Double]) throws -> [Double] {
    var matrix = input, value = rhs, n = rhs.count
    for pivot in 0..<n {
        let selected = (pivot..<n).max { abs(matrix[$0][pivot]) < abs(matrix[$1][pivot]) }!
        guard abs(matrix[selected][pivot]) > 1e-14 else {
            throw NonlinearOptimizationError.invalidEvaluation("sparse KKT matrix is singular")
        }
        matrix.swapAt(pivot, selected); value.swapAt(pivot, selected)
        for row in (pivot + 1)..<n {
            let factor = matrix[row][pivot] / matrix[pivot][pivot]
            for column in pivot..<n { matrix[row][column] -= factor * matrix[pivot][column] }
            value[row] -= factor * value[pivot]
        }
    }
    var solution = [Double](repeating: 0, count: n)
    for row in (0..<n).reversed() {
        let tail = row + 1 < n ? ((row + 1)..<n).reduce(0) { $0 + matrix[row][$1] * solution[$1] } : 0
        solution[row] = (value[row] - tail) / matrix[row][row]
    }
    return solution
}
