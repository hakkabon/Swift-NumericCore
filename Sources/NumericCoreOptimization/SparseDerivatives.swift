import Foundation

/// Coordinate form of one gradient. Indices are sorted and zero entries are omitted.
public struct SparseDerivative: Sendable, Hashable {
    public let dimension: Int
    public let indices: [Int]
    public let values: [Double]

    public init(dimension: Int, indices: [Int], values: [Double]) {
        self.dimension = dimension
        self.indices = indices
        self.values = values
    }

    public var dense: [Double] {
        var result = [Double](repeating: 0, count: dimension)
        for (index, value) in zip(indices, values) { result[index] = value }
        return result
    }
}

/// CSR Jacobian with one row per residual.
public struct SparseJacobian: Sendable, Hashable {
    public let rows: Int
    public let columns: Int
    public let rowPointers: [Int]
    public let columnIndices: [Int]
    public let values: [Double]

    public init(rows: Int, columns: Int, rowPointers: [Int],
                columnIndices: [Int], values: [Double]) {
        self.rows = rows
        self.columns = columns
        self.rowPointers = rowPointers
        self.columnIndices = columnIndices
        self.values = values
    }

    public func multiplying(_ direction: [Double]) throws -> [Double] {
        guard direction.count == columns else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "Jacobian direction dimension does not agree")
        }
        var result = [Double](repeating: 0, count: rows)
        for row in 0..<rows {
            for entry in rowPointers[row]..<rowPointers[row + 1] {
                result[row] += values[entry] * direction[columnIndices[entry]]
            }
        }
        return result
    }

    public func transposeMultiplying(_ weights: [Double]) throws -> [Double] {
        guard weights.count == rows else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "Jacobian transpose weight dimension does not agree")
        }
        var result = [Double](repeating: 0, count: columns)
        for row in 0..<rows {
            for entry in rowPointers[row]..<rowPointers[row + 1] {
                result[columnIndices[entry]] += values[entry] * weights[row]
            }
        }
        return result
    }
}

public struct SparseResidualEvaluation: Sendable, Hashable {
    public let residuals: [Double]
    public let jacobian: SparseJacobian

    public init(residuals: [Double], jacobian: SparseJacobian) {
        self.residuals = residuals
        self.jacobian = jacobian
    }
}

public struct SparseObjectiveEvaluation: Sendable, Hashable {
    public let value: Double
    public let derivative: SparseDerivative

    public init(value: Double, derivative: SparseDerivative) {
        self.value = value
        self.derivative = derivative
    }
}

public extension NonlinearExpression {
    /// Evaluates a value and sparse gradient using a primal sweep followed by
    /// reverse accumulation. Storage is O(nodes + active parameters).
    func evaluateSparse(parameters: [Double]) throws -> (value: Double, derivative: SparseDerivative) {
        let primal = try sparsePrimalValues(parameters)
        var adjoints = [Double](repeating: 0, count: nodes.count)
        adjoints[output] = 1
        if output >= 0 {
            for index in stride(from: output, through: 0, by: -1) {
                let seed = adjoints[index]
                if seed == 0 { continue }
                switch nodes[index] {
                case .constant, .parameter: break
                case .add(let a, let b): adjoints[a] += seed; adjoints[b] += seed
                case .subtract(let a, let b): adjoints[a] += seed; adjoints[b] -= seed
                case .multiply(let a, let b):
                    adjoints[a] += seed * primal[b]; adjoints[b] += seed * primal[a]
                case .divide(let a, let b):
                    adjoints[a] += seed / primal[b]
                    adjoints[b] -= seed * primal[a] / (primal[b] * primal[b])
                case .negate(let a): adjoints[a] -= seed
                case .exp(let a): adjoints[a] += seed * primal[index]
                case .log(let a): adjoints[a] += seed / primal[a]
                case .sqrt(let a): adjoints[a] += seed * 0.5 / primal[index]
                case .sin(let a): adjoints[a] += seed * Foundation.cos(primal[a])
                case .cos(let a): adjoints[a] -= seed * Foundation.sin(primal[a])
                case .pow(let a, let exponent):
                    adjoints[a] += seed * exponent * Foundation.pow(primal[a], exponent - 1)
                }
            }
        }
        var entries: [Int: Double] = [:]
        for (index, node) in nodes.enumerated() {
            if case .parameter(let parameter) = node {
                entries[parameter, default: 0] += adjoints[index]
            }
        }
        guard entries.values.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidEvaluation("expression derivative is non-finite")
        }
        let nonzeros = entries.filter { $0.value != 0 }.sorted { $0.key < $1.key }
        return (primal[output], .init(dimension: parameters.count,
                                      indices: nonzeros.map(\.key),
                                      values: nonzeros.map(\.value)))
    }

    /// Evaluates `f(x)` and `∇f(x)·direction` without constructing `∇f`.
    func evaluateDirectional(parameters: [Double], direction: [Double]) throws
        -> (value: Double, directionalDerivative: Double) {
        try validate(parameterCount: parameters.count)
        guard direction.count == parameters.count, parameters.allSatisfy(\.isFinite),
              direction.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "direction must be finite and match the parameter dimension")
        }
        var primal: [Double] = [], tangent: [Double] = []
        for (index, node) in nodes.enumerated() {
            let pair = sparseDirectionalNode(node, primal, tangent, parameters, direction)
            guard pair.0.isFinite, pair.1.isFinite else {
                throw NonlinearOptimizationError.invalidEvaluation(
                    "expression evaluation produced a non-finite value or derivative")
            }
            primal.append(pair.0); tangent.append(pair.1)
            if index == output { break }
        }
        return (primal[output], tangent[output])
    }

    private func sparsePrimalValues(_ parameters: [Double]) throws -> [Double] {
        try validate(parameterCount: parameters.count)
        guard parameters.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        var values: [Double] = []
        for (index, node) in nodes.enumerated() {
            let value = sparseNodeValue(node, values, parameters)
            guard value.isFinite else {
                throw NonlinearOptimizationError.invalidEvaluation(
                    "expression evaluation produced a non-finite value")
            }
            values.append(value)
            if index == output { break }
        }
        return values
    }
}

public extension NonlinearModel {
    func evaluateSparseObjective(parameters: [Double]) throws -> SparseObjectiveEvaluation {
        try validate()
        guard parameters.count == parameterCount, let objective else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "model does not contain an objective")
        }
        let evaluation = try objective.evaluateSparse(parameters: parameters)
        return .init(value: evaluation.value, derivative: evaluation.derivative)
    }

    func evaluateSparseResiduals(parameters: [Double]) throws -> SparseResidualEvaluation {
        try validate()
        guard parameters.count == parameterCount, !residuals.isEmpty else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "model residual and parameter dimensions do not agree")
        }
        var values: [Double] = [], rowPointers = [0], columns: [Int] = [], entries: [Double] = []
        for expression in residuals {
            let evaluation = try expression.evaluateSparse(parameters: parameters)
            values.append(evaluation.value); columns.append(contentsOf: evaluation.derivative.indices)
            entries.append(contentsOf: evaluation.derivative.values); rowPointers.append(entries.count)
        }
        return .init(residuals: values, jacobian: .init(
            rows: residuals.count, columns: parameterCount, rowPointers: rowPointers,
            columnIndices: columns, values: entries))
    }

    func jacobianVectorProduct(parameters: [Double], direction: [Double]) throws -> [Double] {
        try validate()
        guard parameters.count == parameterCount, direction.count == parameterCount else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "Jacobian product dimensions do not agree")
        }
        return try residuals.map {
            try $0.evaluateDirectional(parameters: parameters, direction: direction).directionalDerivative
        }
    }

    func jacobianTransposeVectorProduct(parameters: [Double], weights: [Double]) throws -> [Double] {
        try validate()
        guard parameters.count == parameterCount, weights.count == residuals.count,
              weights.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "transpose weights must be finite and match the residual dimension")
        }
        var result = [Double](repeating: 0, count: parameterCount)
        for (expression, weight) in zip(residuals, weights) {
            let derivative = try expression.evaluateSparse(parameters: parameters).derivative
            for (index, value) in zip(derivative.indices, derivative.values) {
                result[index] += weight * value
            }
        }
        return result
    }
}

private func sparseNodeValue(_ node: NonlinearNode, _ v: [Double], _ p: [Double]) -> Double {
    switch node {
    case .constant(let x): return x
    case .parameter(let i): return p[i]
    case .add(let a, let b): return v[a] + v[b]
    case .subtract(let a, let b): return v[a] - v[b]
    case .multiply(let a, let b): return v[a] * v[b]
    case .divide(let a, let b): return v[a] / v[b]
    case .negate(let a): return -v[a]
    case .exp(let a): return Foundation.exp(v[a])
    case .log(let a): return Foundation.log(v[a])
    case .sqrt(let a): return Foundation.sqrt(v[a])
    case .sin(let a): return Foundation.sin(v[a])
    case .cos(let a): return Foundation.cos(v[a])
    case .pow(let a, let x): return Foundation.pow(v[a], x)
    }
}

private func sparseDirectionalNode(_ node: NonlinearNode, _ v: [Double], _ d: [Double],
                                   _ p: [Double], _ q: [Double]) -> (Double, Double) {
    switch node {
    case .constant(let x): return (x, 0)
    case .parameter(let i): return (p[i], q[i])
    case .add(let a, let b): return (v[a] + v[b], d[a] + d[b])
    case .subtract(let a, let b): return (v[a] - v[b], d[a] - d[b])
    case .multiply(let a, let b): return (v[a] * v[b], d[a] * v[b] + v[a] * d[b])
    case .divide(let a, let b): return (v[a] / v[b], (d[a] * v[b] - v[a] * d[b]) / (v[b] * v[b]))
    case .negate(let a): return (-v[a], -d[a])
    case .exp(let a): let x = Foundation.exp(v[a]); return (x, x * d[a])
    case .log(let a): return (Foundation.log(v[a]), d[a] / v[a])
    case .sqrt(let a): let x = Foundation.sqrt(v[a]); return (x, 0.5 * d[a] / x)
    case .sin(let a): return (Foundation.sin(v[a]), Foundation.cos(v[a]) * d[a])
    case .cos(let a): return (Foundation.cos(v[a]), -Foundation.sin(v[a]) * d[a])
    case .pow(let a, let x): return (Foundation.pow(v[a], x), x * Foundation.pow(v[a], x - 1) * d[a])
    }
}
