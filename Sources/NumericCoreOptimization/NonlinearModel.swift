import Foundation

/// A node in a topologically ordered, portable scalar expression graph.
/// Every operand index must refer to an earlier node.
public enum NonlinearNode: Sendable, Hashable {
    case constant(Double)
    case parameter(Int)
    case add(Int, Int)
    case subtract(Int, Int)
    case multiply(Int, Int)
    case divide(Int, Int)
    case negate(Int)
    case exp(Int)
    case log(Int)
    case sqrt(Int)
    case sin(Int)
    case cos(Int)
    case pow(Int, Double)
}

public struct DifferentiableValue: Sendable, Hashable {
    public let value: Double
    public let gradient: [Double]
}

public struct NonlinearExpression: Sendable, Hashable {
    public let nodes: [NonlinearNode]
    public let output: Int

    public init(nodes: [NonlinearNode], output: Int) {
        self.nodes = nodes
        self.output = output
    }

    public func validate(parameterCount: Int) throws {
        guard !nodes.isEmpty, nodes.indices.contains(output) else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "expression must contain a valid output node")
        }
        for (index, node) in nodes.enumerated() {
            let earlier: (Int) -> Bool = { $0 >= 0 && $0 < index }
            let valid: Bool
            switch node {
            case .constant(let value): valid = value.isFinite
            case .parameter(let parameter): valid = (0..<parameterCount).contains(parameter)
            case .add(let a, let b), .subtract(let a, let b),
                 .multiply(let a, let b), .divide(let a, let b):
                valid = earlier(a) && earlier(b)
            case .negate(let a), .exp(let a), .log(let a), .sqrt(let a),
                 .sin(let a), .cos(let a): valid = earlier(a)
            case .pow(let a, let exponent): valid = earlier(a) && exponent.isFinite
            }
            guard valid else {
                throw NonlinearOptimizationError.invalidConfiguration(
                    "expression graph is not valid topological form")
            }
        }
    }

    public func evaluate(parameters: [Double]) throws -> DifferentiableValue {
        try validate(parameterCount: parameters.count)
        guard parameters.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        var values: [Double] = []
        var gradients: [[Double]] = []
        let zero = [Double](repeating: 0, count: parameters.count)
        func unary(_ a: Int, value: (Double) -> Double,
                   derivative: (Double) -> Double) -> (Double, [Double]) {
            let factor = derivative(values[a])
            return (value(values[a]), gradients[a].map { factor * $0 })
        }
        func binary(_ a: Int, _ b: Int, value: (Double, Double) -> Double,
                    derivative: (Double, Double) -> (Double, Double)) -> (Double, [Double]) {
            let factors = derivative(values[a], values[b])
            return (value(values[a], values[b]),
                    zip(gradients[a], gradients[b]).map { factors.0 * $0 + factors.1 * $1 })
        }
        for node in nodes {
            let evaluated: (Double, [Double])
            switch node {
            case .constant(let value): evaluated = (value, zero)
            case .parameter(let parameter):
                var gradient = zero; gradient[parameter] = 1
                evaluated = (parameters[parameter], gradient)
            case .add(let a, let b): evaluated = binary(a, b, value: +) { _, _ in (1, 1) }
            case .subtract(let a, let b): evaluated = binary(a, b, value: -) { _, _ in (1, -1) }
            case .multiply(let a, let b): evaluated = binary(a, b, value: *) { x, y in (y, x) }
            case .divide(let a, let b): evaluated = binary(a, b, value: /) { x, y in (1 / y, -x / (y * y)) }
            case .negate(let a): evaluated = unary(a, value: -) { _ in -1 }
            case .exp(let a): evaluated = unary(a, value: Foundation.exp, derivative: Foundation.exp)
            case .log(let a): evaluated = unary(a, value: Foundation.log) { 1 / $0 }
            case .sqrt(let a): evaluated = unary(a, value: Foundation.sqrt) { 0.5 / Foundation.sqrt($0) }
            case .sin(let a): evaluated = unary(a, value: Foundation.sin, derivative: Foundation.cos)
            case .cos(let a): evaluated = unary(a, value: Foundation.cos) { -Foundation.sin($0) }
            case .pow(let a, let exponent):
                evaluated = unary(a, value: { Foundation.pow($0, exponent) },
                                  derivative: { exponent * Foundation.pow($0, exponent - 1) })
            }
            guard evaluated.0.isFinite, evaluated.1.allSatisfy(\.isFinite) else {
                throw NonlinearOptimizationError.invalidEvaluation(
                    "expression evaluation produced a non-finite value or derivative")
            }
            values.append(evaluated.0); gradients.append(evaluated.1)
        }
        return .init(value: values[output], gradient: gradients[output])
    }
}

/// Solver-independent representation of either a scalar objective or a vector
/// of least-squares residuals.
public struct NonlinearModel: Sendable, Hashable {
    public let parameterCount: Int
    public let bounds: [ParameterBound]
    public let objective: NonlinearExpression?
    public let residuals: [NonlinearExpression]

    public static func objective(parameterCount: Int, bounds: [ParameterBound],
                                 expression: NonlinearExpression) throws -> Self {
        let model = Self(parameterCount: parameterCount, bounds: bounds,
                         objective: expression, residuals: [])
        try model.validate(); return model
    }

    public static func leastSquares(parameterCount: Int, bounds: [ParameterBound],
                                    residuals: [NonlinearExpression]) throws -> Self {
        let model = Self(parameterCount: parameterCount, bounds: bounds,
                         objective: nil, residuals: residuals)
        try model.validate(); return model
    }

    private init(parameterCount: Int, bounds: [ParameterBound],
                 objective: NonlinearExpression?, residuals: [NonlinearExpression]) {
        self.parameterCount = parameterCount; self.bounds = bounds
        self.objective = objective; self.residuals = residuals
    }

    public func validate() throws {
        guard parameterCount > 0, bounds.count == parameterCount,
              bounds.allSatisfy(sharedValidBound),
              (objective != nil) != !residuals.isEmpty else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "model requires valid bounds and either one objective or residual expressions")
        }
        try objective?.validate(parameterCount: parameterCount)
        for residual in residuals { try residual.validate(parameterCount: parameterCount) }
    }

    public func evaluateObjective(parameters: [Double]) throws -> DifferentiableValue {
        try validate()
        guard parameters.count == parameterCount, let objective else {
            throw NonlinearOptimizationError.invalidConfiguration("model does not contain an objective")
        }
        return try objective.evaluate(parameters: parameters)
    }

    public func evaluateResiduals(parameters: [Double]) throws -> NonlinearLeastSquaresEvaluation {
        try validate()
        guard parameters.count == parameterCount, !residuals.isEmpty else {
            throw NonlinearOptimizationError.invalidConfiguration("model does not contain residuals")
        }
        let values = try residuals.map { try $0.evaluate(parameters: parameters) }
        return .init(residuals: values.map(\.value), jacobian: values.map(\.gradient))
    }
}

public extension LBFGS {
    static func minimize(model: NonlinearModel, initial: [Double],
                         options: LBFGSOptions = .init(), observer: Observer? = nil) throws -> LBFGSResult {
        try model.validate()
        guard model.bounds.allSatisfy({ $0.lower == nil && $0.upper == nil }) else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "unconstrained L-BFGS cannot ignore model bounds")
        }
        return try minimize(initial: initial, options: options, observer: observer) { point in
            let value = try model.evaluateObjective(parameters: point)
            return (value.value, value.gradient)
        }
    }
}

public extension LBFGSB {
    static func minimize(model: NonlinearModel, initial: [Double],
                         options: LBFGSOptions = .init(), observer: Observer? = nil) throws -> LBFGSResult {
        try model.validate()
        return try minimize(initial: initial, bounds: model.bounds, options: options,
                            observer: observer) { point in
            let value = try model.evaluateObjective(parameters: point)
            return (value.value, value.gradient)
        }
    }
}

public extension NonlinearLeastSquares {
    static func solve(model: NonlinearModel, initial: [Double], weights: [Double] = [],
                      loss: RobustLoss = .squared,
                      options: NonlinearLeastSquaresOptions = .init(),
                      observer: Observer? = nil) throws -> NonlinearLeastSquaresResult {
        try model.validate()
        return try solve(initial: initial, bounds: model.bounds, weights: weights, loss: loss,
                         options: options, observer: observer) { point in
            try model.evaluateResiduals(parameters: point)
        }
    }
}

private func sharedValidBound(_ bound: ParameterBound) -> Bool {
    (bound.lower?.isFinite ?? true) && (bound.upper?.isFinite ?? true)
        && (bound.lower ?? -.infinity) <= (bound.upper ?? .infinity)
}
