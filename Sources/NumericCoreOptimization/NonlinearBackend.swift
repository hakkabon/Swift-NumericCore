import NCBindings

/// Execution choice for portable graph-represented nonlinear models.
/// Closure-based models remain Swift-only because callbacks deliberately do
/// not cross the FFI boundary.
public enum NonlinearBackend: Sendable, Hashable {
    case swift
    case rust
}

/// One result contract and one model representation, independently of where
/// the nonlinear algorithm executes.
public enum NonlinearModelSolver {
    public static func sparseObjective(
        model: NonlinearModel, parameters: [Double], backend: NonlinearBackend = .swift
    ) throws -> SparseObjectiveEvaluation {
        switch backend {
        case .swift: return try model.evaluateSparseObjective(parameters: parameters)
        case .rust:
            do {
                let value = try FFIKernels.evaluateNonlinearObjectiveSparse(
                    model: ffi(model), parameters: parameters)
                return .init(value: value.value, derivative: .init(
                    dimension: value.derivative.dimension, indices: value.derivative.indices,
                    values: value.derivative.values))
            } catch { throw translate(error) }
        }
    }

    public static func sparseResiduals(
        model: NonlinearModel, parameters: [Double], backend: NonlinearBackend = .swift
    ) throws -> SparseResidualEvaluation {
        switch backend {
        case .swift: return try model.evaluateSparseResiduals(parameters: parameters)
        case .rust:
            do {
                let value = try FFIKernels.evaluateNonlinearResidualsSparse(
                    model: ffi(model), parameters: parameters)
                return .init(residuals: value.residuals, jacobian: .init(
                    rows: value.jacobian.rows, columns: value.jacobian.columns,
                    rowPointers: value.jacobian.rowPointers,
                    columnIndices: value.jacobian.columnIndices,
                    values: value.jacobian.values))
            } catch { throw translate(error) }
        }
    }

    public static func jacobianVectorProduct(
        model: NonlinearModel, parameters: [Double], direction: [Double],
        backend: NonlinearBackend = .swift
    ) throws -> [Double] {
        switch backend {
        case .swift: return try model.jacobianVectorProduct(parameters: parameters, direction: direction)
        case .rust:
            do { return try FFIKernels.nonlinearJacobianVectorProduct(
                model: ffi(model), parameters: parameters, direction: direction) }
            catch { throw translate(error) }
        }
    }

    public static func jacobianTransposeVectorProduct(
        model: NonlinearModel, parameters: [Double], weights: [Double],
        backend: NonlinearBackend = .swift
    ) throws -> [Double] {
        switch backend {
        case .swift: return try model.jacobianTransposeVectorProduct(parameters: parameters, weights: weights)
        case .rust:
            do { return try FFIKernels.nonlinearJacobianTransposeVectorProduct(
                model: ffi(model), parameters: parameters, weights: weights) }
            catch { throw translate(error) }
        }
    }

    public static func minimize(
        model: NonlinearModel, initial: [Double], backend: NonlinearBackend = .swift,
        options: LBFGSOptions = .init()
    ) throws -> LBFGSResult {
        try model.validate()
        try validatePortable(options)
        switch backend {
        case .swift:
            return try LBFGSB.minimize(model: model, initial: initial, options: options)
        case .rust:
            do {
                return lbfgs(try FFIKernels.solveNonlinearObjective(
                    model: ffi(model), initial: initial, options: ffi(options)))
            } catch { throw translate(error) }
        }
    }

    public static func leastSquares(
        model: NonlinearModel, initial: [Double], weights: [Double] = [],
        loss: RobustLoss = .squared, backend: NonlinearBackend = .swift,
        options: NonlinearLeastSquaresOptions = .init()
    ) throws -> NonlinearLeastSquaresResult {
        try model.validate()
        guard options.maxIterations >= 0, options.maxDampingIterations >= 0 else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "iteration limits must be non-negative")
        }
        switch backend {
        case .swift:
            return try NonlinearLeastSquares.solve(
                model: model, initial: initial, weights: weights, loss: loss, options: options)
        case .rust:
            do {
                let value = try FFIKernels.solveNonlinearLeastSquares(
                    model: ffi(model), initial: initial, weights: weights,
                    loss: ffi(loss), options: ffi(options))
                return .init(
                    point: value.point, residuals: value.residuals, cost: value.cost,
                    gradientNorm: value.gradientNorm, iterations: value.iterations,
                    evaluations: value.evaluations, termination: termination(value.termination),
                    finalDamping: value.finalDamping, acceptedSteps: value.acceptedSteps,
                    rejectedSteps: value.rejectedSteps)
            } catch { throw translate(error) }
        }
    }

    public static func minimize(
        problem: ConstrainedNonlinearProblem, initial: [Double],
        backend: NonlinearBackend = .swift, options: ConstrainedOptions = .init()
    ) throws -> ConstrainedResult {
        try problem.validate()
        guard options.maxOuterIterations >= 0 else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "iteration limits must be non-negative")
        }
        try validatePortable(options.innerOptions)
        switch backend {
        case .swift:
            return try ConstrainedNonlinearSolver.minimize(
                problem: problem, initial: initial, options: options)
        case .rust:
            do {
                let value = try FFIKernels.solveConstrainedNonlinear(
                    model: ffi(problem.model),
                    constraints: problem.constraints.map { .init(
                        expression: ffi($0.expression), bound: ffi($0.bound)) },
                    initial: initial, options: ffi(options))
                return .init(
                    point: value.point, objective: value.objective,
                    constraintValues: value.constraintValues,
                    multipliers: value.multipliers.map { .init(
                        lower: $0.lower, upper: $0.upper, equality: $0.equality) },
                    maximumViolation: value.maximumViolation,
                    stationarityNorm: value.stationarityNorm,
                    outerIterations: value.outerIterations,
                    innerIterations: value.innerIterations, evaluations: value.evaluations,
                    finalPenalty: value.finalPenalty,
                    termination: constrainedTermination(value.termination))
            } catch { throw translate(error) }
        }
    }

    private static func ffi(_ model: NonlinearModel) -> FFINonlinearModel {
        .init(parameterCount: model.parameterCount, bounds: model.bounds.map(ffi),
              objective: model.objective.map(ffi), residuals: model.residuals.map(ffi))
    }

    private static func ffi(_ expression: NonlinearExpression) -> FFINonlinearExpression {
        .init(nodes: expression.nodes.map(ffi), output: expression.output)
    }

    private static func ffi(_ node: NonlinearNode) -> FFINonlinearNode {
        switch node {
        case .constant(let value): return .constant(value)
        case .parameter(let value): return .parameter(value)
        case .add(let a, let b): return .add(a, b)
        case .subtract(let a, let b): return .subtract(a, b)
        case .multiply(let a, let b): return .multiply(a, b)
        case .divide(let a, let b): return .divide(a, b)
        case .negate(let a): return .negate(a)
        case .exp(let a): return .exp(a)
        case .log(let a): return .log(a)
        case .sqrt(let a): return .sqrt(a)
        case .sin(let a): return .sin(a)
        case .cos(let a): return .cos(a)
        case .pow(let a, let value): return .pow(a, value)
        }
    }

    private static func ffi(_ bound: ParameterBound) -> FFIBound {
        .init(lower: bound.lower, upper: bound.upper)
    }

    private static func ffi(_ options: LBFGSOptions) -> FFILBFGSOptions {
        .init(maxIterations: options.maxIterations, historySize: options.historySize,
              gradientTolerance: options.gradientTolerance,
              stepTolerance: options.stepTolerance,
              objectiveTolerance: options.objectiveTolerance,
              maxLineSearchIterations: options.maxLineSearchIterations,
              armijo: options.armijo, wolfe: options.wolfe,
              backtracking: options.backtracking)
    }

    private static func validatePortable(_ options: LBFGSOptions) throws {
        guard options.maxIterations >= 0, options.historySize >= 0,
              options.maxLineSearchIterations >= 0 else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "iteration and history limits must be non-negative")
        }
    }

    private static func ffi(_ loss: RobustLoss) -> FFIRobustLoss {
        switch loss {
        case .squared: return .squared
        case .huber(let scale): return .huber(scale: scale)
        case .cauchy(let scale): return .cauchy(scale: scale)
        }
    }

    private static func ffi(_ options: NonlinearLeastSquaresOptions)
        -> FFINonlinearLeastSquaresOptions {
        .init(maxIterations: options.maxIterations,
              gradientTolerance: options.gradientTolerance,
              stepTolerance: options.stepTolerance, costTolerance: options.costTolerance,
              initialDamping: options.initialDamping,
              dampingIncrease: options.dampingIncrease,
              dampingDecrease: options.dampingDecrease,
              maxDampingIterations: options.maxDampingIterations)
    }

    private static func ffi(_ options: ConstrainedOptions) -> FFIConstrainedOptions {
        .init(maxOuterIterations: options.maxOuterIterations,
              feasibilityTolerance: options.feasibilityTolerance,
              stationarityTolerance: options.stationarityTolerance,
              initialPenalty: options.initialPenalty,
              penaltyIncrease: options.penaltyIncrease,
              maximumPenalty: options.maximumPenalty,
              innerOptions: ffi(options.innerOptions))
    }

    private static func lbfgs(_ value: FFILBFGSResult) -> LBFGSResult {
        .init(point: value.point, objective: value.objective, gradient: value.gradient,
              iterations: value.iterations, evaluations: value.evaluations,
              termination: termination(value.termination), gradientNorm: value.gradientNorm,
              acceptedStep: value.acceptedStep,
              storedCurvaturePairs: value.storedCurvaturePairs)
    }

    private static func termination(_ value: FFINonlinearTermination) -> NonlinearTermination {
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

    private static func constrainedTermination(_ value: FFIConstrainedTermination)
        -> ConstrainedTermination {
        switch value {
        case .converged: return .converged
        case .iterationLimit: return .iterationLimit
        case .penaltyLimit: return .penaltyLimit
        case .cancelled: return .cancelled
        }
    }

    private static func translate(_ error: Error) -> Error {
        guard let ffi = error as? FFIError else { return error }
        switch ffi {
        case .dimensionMismatch(let message), .solverError(let message), .unknown(let message):
            return NonlinearOptimizationError.invalidConfiguration(message)
        }
    }
}
