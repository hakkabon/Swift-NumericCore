/// Stable Swift-facing transport for graph-represented nonlinear models.
/// Generated UniFFI types remain private to this adapter layer.
public enum FFINonlinearNode: Sendable, Hashable {
    case constant(Double), parameter(Int)
    case add(Int, Int), subtract(Int, Int), multiply(Int, Int), divide(Int, Int)
    case negate(Int), exp(Int), log(Int), sqrt(Int), sin(Int), cos(Int), pow(Int, Double)
}

public struct FFINonlinearExpression: Sendable, Hashable {
    public let nodes: [FFINonlinearNode]
    public let output: Int
    public init(nodes: [FFINonlinearNode], output: Int) { self.nodes = nodes; self.output = output }
}

public struct FFINonlinearModel: Sendable, Hashable {
    public let parameterCount: Int
    public let bounds: [FFIBound]
    public let objective: FFINonlinearExpression?
    public let residuals: [FFINonlinearExpression]
    public init(parameterCount: Int, bounds: [FFIBound], objective: FFINonlinearExpression?,
                residuals: [FFINonlinearExpression]) {
        self.parameterCount = parameterCount; self.bounds = bounds
        self.objective = objective; self.residuals = residuals
    }
}

public struct FFINonlinearConstraint: Sendable, Hashable {
    public let expression: FFINonlinearExpression
    public let bound: FFIBound
    public init(expression: FFINonlinearExpression, bound: FFIBound) {
        self.expression = expression; self.bound = bound
    }
}

public struct FFILBFGSOptions: Sendable, Hashable {
    public var maxIterations: Int, historySize: Int
    public var gradientTolerance: Double, stepTolerance: Double, objectiveTolerance: Double
    public var maxLineSearchIterations: Int
    public var armijo: Double, wolfe: Double, backtracking: Double
    public init(maxIterations: Int, historySize: Int, gradientTolerance: Double,
                stepTolerance: Double, objectiveTolerance: Double,
                maxLineSearchIterations: Int, armijo: Double, wolfe: Double,
                backtracking: Double) {
        self.maxIterations = maxIterations; self.historySize = historySize
        self.gradientTolerance = gradientTolerance; self.stepTolerance = stepTolerance
        self.objectiveTolerance = objectiveTolerance
        self.maxLineSearchIterations = maxLineSearchIterations
        self.armijo = armijo; self.wolfe = wolfe; self.backtracking = backtracking
    }
}

public enum FFINonlinearTermination: Sendable, Hashable {
    case convergedGradient, convergedStep, convergedObjective, iterationLimit
    case lineSearchFailed, dampingLimit, cancelled
}

public struct FFILBFGSResult: Sendable, Hashable {
    public let point: [Double], objective: Double, gradient: [Double]
    public let iterations: Int, evaluations: Int
    public let termination: FFINonlinearTermination
    public let gradientNorm: Double, acceptedStep: Double?
    public let storedCurvaturePairs: Int
}

public enum FFIRobustLoss: Sendable, Hashable {
    case squared, huber(scale: Double), cauchy(scale: Double)
}

public struct FFINonlinearLeastSquaresOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var gradientTolerance: Double, stepTolerance: Double, costTolerance: Double
    public var initialDamping: Double, dampingIncrease: Double, dampingDecrease: Double
    public var maxDampingIterations: Int
    public init(maxIterations: Int, gradientTolerance: Double, stepTolerance: Double,
                costTolerance: Double, initialDamping: Double, dampingIncrease: Double,
                dampingDecrease: Double, maxDampingIterations: Int) {
        self.maxIterations = maxIterations; self.gradientTolerance = gradientTolerance
        self.stepTolerance = stepTolerance; self.costTolerance = costTolerance
        self.initialDamping = initialDamping; self.dampingIncrease = dampingIncrease
        self.dampingDecrease = dampingDecrease; self.maxDampingIterations = maxDampingIterations
    }
}

public struct FFINonlinearLeastSquaresResult: Sendable, Hashable {
    public let point: [Double], residuals: [Double]
    public let cost: Double, gradientNorm: Double
    public let iterations: Int, evaluations: Int
    public let termination: FFINonlinearTermination
    public let finalDamping: Double
    public let acceptedSteps: Int, rejectedSteps: Int
}

public struct FFIConstrainedOptions: Sendable, Hashable {
    public var maxOuterIterations: Int
    public var feasibilityTolerance: Double, stationarityTolerance: Double
    public var initialPenalty: Double, penaltyIncrease: Double, maximumPenalty: Double
    public var innerOptions: FFILBFGSOptions
    public init(maxOuterIterations: Int, feasibilityTolerance: Double,
                stationarityTolerance: Double, initialPenalty: Double,
                penaltyIncrease: Double, maximumPenalty: Double,
                innerOptions: FFILBFGSOptions) {
        self.maxOuterIterations = maxOuterIterations
        self.feasibilityTolerance = feasibilityTolerance
        self.stationarityTolerance = stationarityTolerance
        self.initialPenalty = initialPenalty; self.penaltyIncrease = penaltyIncrease
        self.maximumPenalty = maximumPenalty; self.innerOptions = innerOptions
    }
}

public enum FFIConstrainedTermination: Sendable, Hashable {
    case converged, iterationLimit, penaltyLimit, cancelled
}

public struct FFIConstraintMultiplier: Sendable, Hashable {
    public let lower: Double, upper: Double, equality: Double
}

public struct FFIConstrainedResult: Sendable, Hashable {
    public let point: [Double], objective: Double, constraintValues: [Double]
    public let multipliers: [FFIConstraintMultiplier]
    public let maximumViolation: Double, stationarityNorm: Double
    public let outerIterations: Int, innerIterations: Int, evaluations: Int
    public let finalPenalty: Double
    public let termination: FFIConstrainedTermination
}

public struct FFISparseDerivative: Sendable, Hashable {
    public let dimension: Int
    public let indices: [Int]
    public let values: [Double]
}

public struct FFISparseJacobian: Sendable, Hashable {
    public let rows: Int, columns: Int
    public let rowPointers: [Int], columnIndices: [Int]
    public let values: [Double]
}

public struct FFISparseObjectiveEvaluation: Sendable, Hashable {
    public let value: Double
    public let derivative: FFISparseDerivative
}

public struct FFISparseResidualEvaluation: Sendable, Hashable {
    public let residuals: [Double]
    public let jacobian: FFISparseJacobian
}

extension FFIKernels {
    public static func evaluateNonlinearObjectiveSparse(
        model: FFINonlinearModel, parameters: [Double]
    ) throws -> FFISparseObjectiveEvaluation {
        do {
            let result = try NCBindings.evaluateNonlinearObjectiveSparse(
                modelValue: ffi(model), parameters: parameters)
            return .init(value: result.value, derivative: .init(
                dimension: Int(result.derivative.dimension),
                indices: result.derivative.indices.map(Int.init),
                values: result.derivative.values))
        } catch { throw Self.translate(error) }
    }

    public static func evaluateNonlinearResidualsSparse(
        model: FFINonlinearModel, parameters: [Double]
    ) throws -> FFISparseResidualEvaluation {
        do {
            let result = try NCBindings.evaluateNonlinearResidualsSparse(
                modelValue: ffi(model), parameters: parameters)
            return .init(residuals: result.residuals, jacobian: .init(
                rows: Int(result.jacobian.rows), columns: Int(result.jacobian.columns),
                rowPointers: result.jacobian.rowPointers.map(Int.init),
                columnIndices: result.jacobian.columnIndices.map(Int.init),
                values: result.jacobian.values))
        } catch { throw Self.translate(error) }
    }

    public static func nonlinearJacobianVectorProduct(
        model: FFINonlinearModel, parameters: [Double], direction: [Double]
    ) throws -> [Double] {
        do { return try NCBindings.nonlinearJacobianVectorProduct(
            modelValue: ffi(model), parameters: parameters, direction: direction) }
        catch { throw Self.translate(error) }
    }

    public static func nonlinearJacobianTransposeVectorProduct(
        model: FFINonlinearModel, parameters: [Double], weights: [Double]
    ) throws -> [Double] {
        do { return try NCBindings.nonlinearJacobianTransposeVectorProduct(
            modelValue: ffi(model), parameters: parameters, weights: weights) }
        catch { throw Self.translate(error) }
    }

    public static func solveNonlinearObjective(
        model: FFINonlinearModel, initial: [Double], options: FFILBFGSOptions
    ) throws -> FFILBFGSResult {
        do {
            let value = try NCBindings.solveNonlinearObjective(
                modelValue: ffi(model), initial: initial, options: ffi(options))
            return FFILBFGSResult(
                point: value.point, objective: value.objective, gradient: value.gradient,
                iterations: Int(value.iterations), evaluations: Int(value.evaluations),
                termination: termination(value.termination), gradientNorm: value.gradientNorm,
                acceptedStep: value.acceptedStep,
                storedCurvaturePairs: Int(value.storedCurvaturePairs))
        } catch { throw Self.translate(error) }
    }

    public static func solveNonlinearLeastSquares(
        model: FFINonlinearModel, initial: [Double], weights: [Double],
        loss: FFIRobustLoss, options: FFINonlinearLeastSquaresOptions
    ) throws -> FFINonlinearLeastSquaresResult {
        do {
            let value = try NCBindings.solveNonlinearLeastSquares(
                modelValue: ffi(model), initial: initial, weights: weights,
                loss: ffi(loss), options: FfiNonlinearLeastSquaresOptions(
                    maxIterations: UInt64(options.maxIterations),
                    gradientTolerance: options.gradientTolerance,
                    stepTolerance: options.stepTolerance, costTolerance: options.costTolerance,
                    initialDamping: options.initialDamping,
                    dampingIncrease: options.dampingIncrease,
                    dampingDecrease: options.dampingDecrease,
                    maxDampingIterations: UInt64(options.maxDampingIterations)))
            return FFINonlinearLeastSquaresResult(
                point: value.point, residuals: value.residuals, cost: value.cost,
                gradientNorm: value.gradientNorm, iterations: Int(value.iterations),
                evaluations: Int(value.evaluations), termination: termination(value.termination),
                finalDamping: value.finalDamping, acceptedSteps: Int(value.acceptedSteps),
                rejectedSteps: Int(value.rejectedSteps))
        } catch { throw Self.translate(error) }
    }

    public static func solveConstrainedNonlinear(
        model: FFINonlinearModel, constraints: [FFINonlinearConstraint], initial: [Double],
        options: FFIConstrainedOptions
    ) throws -> FFIConstrainedResult {
        do {
            let value = try NCBindings.solveConstrainedNonlinear(
                modelValue: ffi(model),
                constraints: constraints.map { FfiNonlinearConstraint(
                    expression: ffi($0.expression),
                    bound: FfiBound(lower: $0.bound.lower, upper: $0.bound.upper)) },
                initial: initial,
                options: FfiConstrainedOptions(
                    maxOuterIterations: UInt64(options.maxOuterIterations),
                    feasibilityTolerance: options.feasibilityTolerance,
                    stationarityTolerance: options.stationarityTolerance,
                    initialPenalty: options.initialPenalty,
                    penaltyIncrease: options.penaltyIncrease,
                    maximumPenalty: options.maximumPenalty,
                    innerOptions: ffi(options.innerOptions)))
            let status: FFIConstrainedTermination
            switch value.termination {
            case .converged: status = .converged
            case .iterationLimit: status = .iterationLimit
            case .penaltyLimit: status = .penaltyLimit
            case .cancelled: status = .cancelled
            }
            return FFIConstrainedResult(
                point: value.point, objective: value.objective,
                constraintValues: value.constraintValues,
                multipliers: value.multipliers.map { .init(
                    lower: $0.lower, upper: $0.upper, equality: $0.equality) },
                maximumViolation: value.maximumViolation,
                stationarityNorm: value.stationarityNorm,
                outerIterations: Int(value.outerIterations),
                innerIterations: Int(value.innerIterations), evaluations: Int(value.evaluations),
                finalPenalty: value.finalPenalty, termination: status)
        } catch { throw Self.translate(error) }
    }

    private static func ffi(_ model: FFINonlinearModel) -> FfiNonlinearModel {
        FfiNonlinearModel(
            parameterCount: UInt32(model.parameterCount),
            bounds: model.bounds.map { FfiBound(lower: $0.lower, upper: $0.upper) },
            objective: model.objective.map(ffi), residuals: model.residuals.map(ffi))
    }

    private static func ffi(_ expression: FFINonlinearExpression) -> FfiNonlinearExpression {
        FfiNonlinearExpression(nodes: expression.nodes.map(ffi), output: UInt32(expression.output))
    }

    private static func ffi(_ node: FFINonlinearNode) -> FfiNonlinearNode {
        func make(_ kind: FfiNonlinearNodeKind, _ first: Int = 0,
                  _ second: Int = 0, value: Double = 0) -> FfiNonlinearNode {
            FfiNonlinearNode(kind: kind, first: UInt32(first), second: UInt32(second), value: value)
        }
        switch node {
        case .constant(let value): return make(.constant, value: value)
        case .parameter(let p): return make(.parameter, p)
        case .add(let a, let b): return make(.add, a, b)
        case .subtract(let a, let b): return make(.subtract, a, b)
        case .multiply(let a, let b): return make(.multiply, a, b)
        case .divide(let a, let b): return make(.divide, a, b)
        case .negate(let a): return make(.negate, a)
        case .exp(let a): return make(.exp, a)
        case .log(let a): return make(.log, a)
        case .sqrt(let a): return make(.sqrt, a)
        case .sin(let a): return make(.sin, a)
        case .cos(let a): return make(.cos, a)
        case .pow(let a, let p): return make(.pow, a, value: p)
        }
    }

    private static func ffi(_ options: FFILBFGSOptions) -> FfiLbfgsOptions {
        FfiLbfgsOptions(
            maxIterations: UInt64(options.maxIterations), historySize: UInt64(options.historySize),
            gradientTolerance: options.gradientTolerance, stepTolerance: options.stepTolerance,
            objectiveTolerance: options.objectiveTolerance,
            maxLineSearchIterations: UInt64(options.maxLineSearchIterations),
            armijo: options.armijo, wolfe: options.wolfe, backtracking: options.backtracking)
    }

    private static func ffi(_ loss: FFIRobustLoss) -> FfiRobustLoss {
        switch loss {
        case .squared: return .init(kind: .squared, scale: 1)
        case .huber(let scale): return .init(kind: .huber, scale: scale)
        case .cauchy(let scale): return .init(kind: .cauchy, scale: scale)
        }
    }

    private static func termination(_ value: FfiNonlinearTermination) -> FFINonlinearTermination {
        switch value {
        case .convergedGradient: return .convergedGradient
        case .convergedStep: return .convergedStep
        case .convergedObjective: return .convergedObjective
        case .iterationLimit: return .iterationLimit
        case .lineSearchFailed: return .lineSearchFailed
        case .dampingLimit: return .dampingLimit
        case .cancelled: return .cancelled
        }
    }
}
