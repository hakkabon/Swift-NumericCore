import NumericCoreOptimization

public enum NonlinearPresolveError: Error, Equatable {
    case noObjective
    @available(*, deprecated, message: "integer nonlinear models are supported")
    case integerVariablesUnsupported
    case constraintsRequired
}

/// Graph-compiled nonlinear AMPL model. Objective and constraints use the same
/// representation as the programmatic nonlinear API and therefore share its
/// Swift/Rust solver boundary.
public struct CompiledNonlinearProblem: Sendable, Hashable {
    public let variableNames: [String]
    public let constraintNames: [String]
    public let model: NonlinearModel
    public let constraints: [NonlinearConstraint]
    public let objectiveSign: Double
    public let defaultInitialPoint: [Double]
    public let isInteger: [Bool]
}

public extension Model {
    func compileNonlinear() throws -> CompiledNonlinearProblem {
        guard let objective else { throw NonlinearPresolveError.noObjective }
        var seenNames = Set<String>()
        for name in variableNames where !seenNames.insert(name).inserted {
            throw PresolveError.duplicateVariableName(name)
        }
        let objectiveSource = objective.algebraicExpression ?? objective.expression.algebraic
        var objectiveCompiler = NonlinearGraphCompiler()
        var objectiveOutput = objectiveCompiler.append(objectiveSource)
        if objective.sense == .maximize {
            objectiveOutput = objectiveCompiler.appendNode(.negate(objectiveOutput))
        }
        let objectiveGraph = NonlinearExpression(
            nodes: objectiveCompiler.nodes, output: objectiveOutput)
        let bounds = variableBounds.map {
            ParameterBound(lower: $0.lower, upper: $0.upper)
        }
        let model = try NonlinearModel.objective(
            parameterCount: variableNames.count, bounds: bounds, expression: objectiveGraph)
        let nonlinearConstraints = constraints.map { constraint in
            let lhs = constraint.algebraicLHS ?? constraint.lhs.algebraic
            let rhs = constraint.algebraicRHS ?? constraint.rhs.algebraic
            var compiler = NonlinearGraphCompiler()
            let left = compiler.append(lhs), right = compiler.append(rhs)
            let output = compiler.appendNode(.subtract(left, right))
            let expression = NonlinearExpression(nodes: compiler.nodes, output: output)
            let bound: ParameterBound
            switch constraint.relation {
            case .lessThanOrEqual: bound = .init(upper: 0)
            case .greaterThanOrEqual: bound = .init(lower: 0)
            case .equal: bound = .fixed(0)
            }
            return NonlinearConstraint(expression: expression, bound: bound)
        }
        return .init(
            variableNames: variableNames,
            constraintNames: constraints.map(\.name),
            model: model, constraints: nonlinearConstraints,
            objectiveSign: objective.sense == .minimize ? 1 : -1,
            defaultInitialPoint: bounds.map(Self.defaultInitialPoint),
            isInteger: variableIsInteger)
    }

    private static func defaultInitialPoint(_ bound: ParameterBound) -> Double {
        let lower = bound.lower ?? -.infinity, upper = bound.upper ?? .infinity
        if lower <= 0, 0 <= upper { return 0 }
        if lower.isFinite, upper.isFinite { return 0.5 * (lower + upper) }
        if lower.isFinite { return lower }
        if upper.isFinite { return upper }
        return 0
    }
}

private extension LinearExpression {
    var algebraic: AlgebraicExpression {
        var result: AlgebraicExpression = .constant(constant)
        for (index, coefficient) in coefficients.sorted(by: { $0.key < $1.key }) {
            result = .add(result, .multiply(.constant(coefficient), .variable(index)))
        }
        return result
    }
}

private struct NonlinearGraphCompiler {
    var nodes: [NonlinearNode] = []

    mutating func appendNode(_ node: NonlinearNode) -> Int {
        nodes.append(node); return nodes.count - 1
    }

    mutating func append(_ expression: AlgebraicExpression) -> Int {
        switch expression {
        case .constant(let value): return appendNode(.constant(value))
        case .variable(let index): return appendNode(.parameter(index))
        case .add(let lhs, let rhs): return binary(lhs, rhs, NonlinearNode.add)
        case .subtract(let lhs, let rhs): return binary(lhs, rhs, NonlinearNode.subtract)
        case .multiply(let lhs, let rhs): return binary(lhs, rhs, NonlinearNode.multiply)
        case .divide(let lhs, let rhs): return binary(lhs, rhs, NonlinearNode.divide)
        case .negate(let value): return appendNode(.negate(append(value)))
        case .power(let value, let exponent): return appendNode(.pow(append(value), exponent))
        case .exp(let value): return appendNode(.exp(append(value)))
        case .log(let value): return appendNode(.log(append(value)))
        case .sqrt(let value): return appendNode(.sqrt(append(value)))
        case .sin(let value): return appendNode(.sin(append(value)))
        case .cos(let value): return appendNode(.cos(append(value)))
        }
    }

    mutating func binary(
        _ lhs: AlgebraicExpression, _ rhs: AlgebraicExpression,
        _ make: (Int, Int) -> NonlinearNode
    ) -> Int {
        let left = append(lhs), right = append(rhs)
        return appendNode(make(left, right))
    }
}
