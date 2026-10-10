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
    public static func restoreFeasibility(
        problem: ConstrainedNonlinearProblem, initial: [Double],
        backend: NonlinearBackend = .swift,
        options: FeasibilityRestorationOptions = .init()
    ) throws -> FeasibilityRestorationResult {
        switch backend {
        case .swift:
            return try FeasibilityRestoration.restore(
                problem: problem, initial: initial, options: options)
        case .rust:
            do {
                let value = try FFIKernels.restoreNonlinearFeasibility(
                    model: ffi(problem.model), constraints: problem.constraints.map {
                        .init(expression: ffi($0.expression), bound: ffi($0.bound))
                    }, initial: initial,
                    options: .init(maxIterations: options.maxIterations,
                                   feasibilityTolerance: options.feasibilityTolerance,
                                   interiorMargin: options.interiorMargin))
                let termination: FeasibilityRestorationTermination
                switch value.termination {
                case .alreadyFeasible: termination = .alreadyFeasible
                case .converged: termination = .converged
                case .iterationLimit: termination = .iterationLimit
                case .stalled: termination = .stalled
                }
                return .init(point: value.point, maximumViolation: value.maximumViolation,
                             squaredViolation: value.squaredViolation,
                             iterations: value.iterations, evaluations: value.evaluations,
                             termination: termination)
            } catch { throw translate(error) }
        }
    }

    public static func minimizeMixedInteger(
        problem: MixedIntegerNonlinearProblem, initial: [Double],
        backend: NonlinearBackend = .swift,
        options: MixedIntegerNonlinearOptions = .init()
    ) throws -> MixedIntegerNonlinearResult {
        switch backend {
        case .swift:
            return try MixedIntegerNonlinearSolver.minimize(
                problem: problem, initial: initial, options: options)
        case .rust:
            do {
                let strategy: FFINonlinearRelaxationStrategy =
                    options.relaxationStrategy == .sqp ? .sqp : .augmentedLagrangian
                let nodeSelection: FFIMINLPNodeSelection =
                    options.nodeSelection == .depthFirst ? .depthFirst : .bestLocalBound
                let value = try FFIKernels.solveMixedIntegerNonlinear(
                    model: ffi(problem.model),
                    constraints: problem.constraints.map { .init(
                        expression: ffi($0.expression), bound: ffi($0.bound)) },
                    isInteger: problem.isInteger, initial: initial,
                    options: .init(maxNodes: options.maxNodes,
                                   integerTolerance: options.integerTolerance,
                                   feasibilityTolerance: options.feasibilityTolerance,
                                   absoluteGapTolerance: options.absoluteGapTolerance,
                                   relativeGapTolerance: options.relativeGapTolerance,
                                   relaxationStrategy: strategy,
                                   nodeSelection: nodeSelection,
                                   enableRoundingHeuristic: options.enableRoundingHeuristic,
                                   initialIncumbent: options.initialIncumbent ?? []))
                let termination: MixedIntegerNonlinearTermination
                switch value.termination {
                case .searchExhausted: termination = .searchExhausted
                case .localGapLimit: termination = .localGapLimit
                case .nodeLimit: termination = .nodeLimit
                case .infeasible: termination = .infeasible
                case .relaxationFailure: termination = .relaxationFailure
                case .cancelled: termination = .cancelled
                }
                return .init(point: value.point, objective: value.objective,
                             constraintValues: value.constraintValues,
                             multipliers: value.multipliers.map { .init(
                                lower: $0.lower, upper: $0.upper, equality: $0.equality) },
                             maximumViolation: value.maximumViolation,
                             stationarityNorm: value.stationarityNorm,
                             nodesExplored: value.nodesExplored,
                             relaxationsSolved: value.relaxationsSolved,
                             nodesPrunedInfeasible: value.nodesPrunedInfeasible,
                             maximumDepth: value.maximumDepth,
                             incumbentsFound: value.incumbentsFound,
                             heuristicAttempts: value.heuristicAttempts,
                             heuristicSuccesses: value.heuristicSuccesses,
                             warmIncumbentAccepted: value.warmIncumbentAccepted,
                             bestRelaxationObjective: value.bestRelaxationObjective,
                             absoluteGap: value.absoluteGap,
                             relativeGap: value.relativeGap,
                             globalOptimalityCertified: value.globalOptimalityCertified,
                             termination: termination)
            } catch { throw translate(error) }
        }
    }

    public static func minimizeInteriorPoint(
        problem: ConstrainedNonlinearProblem, initial: [Double],
        backend: NonlinearBackend = .swift,
        options: NonlinearInteriorPointOptions = .init()
    ) throws -> NonlinearInteriorPointResult {
        try problem.validate()
        guard options.maxOuterIterations > 0, options.maxInnerIterations > 0,
              options.maxLineSearchIterations > 0 else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "iteration limits must be positive")
        }
        switch backend {
        case .swift:
            return try NonlinearInteriorPointSolver.minimize(
                problem: problem, initial: initial, options: options)
        case .rust:
            do {
                let value = try FFIKernels.solveNonlinearInteriorPoint(
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
                    complementarity: value.complementarity,
                    outerIterations: value.outerIterations,
                    innerIterations: value.innerIterations, evaluations: value.evaluations,
                    finalBarrier: value.finalBarrier,
                    acceptedSteps: value.acceptedSteps, rejectedSteps: value.rejectedSteps,
                    termination: interiorPointTermination(value.termination))
            } catch { throw translate(error) }
        }
    }

    public static func minimizeSQP(
        problem: ConstrainedNonlinearProblem, initial: [Double],
        backend: NonlinearBackend = .swift, options: SQPOptions = .init()
    ) throws -> SQPResult {
        try problem.validate()
        guard options.maxIterations >= 0, options.maxLineSearchIterations >= 0,
              options.qpOptions.maxIterations >= 0 else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "iteration limits must be non-negative")
        }
        switch backend {
        case .swift:
            return try SequentialQuadraticProgramming.minimize(
                problem: problem, initial: initial, options: options)
        case .rust:
            do {
                let value = try FFIKernels.solveSQP(
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
                    iterations: value.iterations, evaluations: value.evaluations,
                    acceptedSteps: value.acceptedSteps, rejectedSteps: value.rejectedSteps,
                    finalMeritPenalty: value.finalMeritPenalty,
                    lastStepNorm: value.lastStepNorm,
                    termination: sqpTermination(value.termination))
            } catch { throw translate(error) }
        }
    }

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

    public static func secondOrderObjective(
        model: NonlinearModel, parameters: [Double], backend: NonlinearBackend = .swift
    ) throws -> SecondOrderValue {
        guard let objective = model.objective else {
            throw NonlinearOptimizationError.invalidConfiguration("model does not contain an objective")
        }
        switch backend {
        case .swift: return try objective.evaluateSecondOrder(parameters: parameters)
        case .rust:
            do {
                let value = try FFIKernels.evaluateNonlinearObjectiveSecondOrder(
                    model: ffi(model), parameters: parameters)
                return .init(value: value.value, gradient: value.gradient, hessian: value.hessian)
            } catch { throw translate(error) }
        }
    }

    public static func sparseObjectiveHessian(
        model: NonlinearModel, parameters: [Double], zeroTolerance: Double = 0,
        backend: NonlinearBackend = .swift
    ) throws -> SparseHessian {
        guard let objective = model.objective else {
            throw NonlinearOptimizationError.invalidConfiguration("model does not contain an objective")
        }
        switch backend {
        case .swift:
            return try objective.evaluateSparseHessian(
                parameters: parameters, zeroTolerance: zeroTolerance).hessian
        case .rust:
            do {
                let value = try FFIKernels.evaluateNonlinearObjectiveSparseHessian(
                    model: ffi(model), parameters: parameters, zeroTolerance: zeroTolerance)
                return .init(dimension: value.dimension, rowPointers: value.rowPointers,
                             columnIndices: value.columnIndices, values: value.values)
            } catch { throw translate(error) }
        }
    }

    public static func objectiveHessianVectorProduct(
        model: NonlinearModel, parameters: [Double], direction: [Double],
        backend: NonlinearBackend = .swift
    ) throws -> [Double] {
        guard let objective = model.objective else {
            throw NonlinearOptimizationError.invalidConfiguration("model does not contain an objective")
        }
        switch backend {
        case .swift: return try objective.hessianVectorProduct(
            parameters: parameters, direction: direction)
        case .rust:
            do { return try FFIKernels.evaluateNonlinearObjectiveHessianVectorProduct(
                model: ffi(model), parameters: parameters, direction: direction) }
            catch { throw translate(error) }
        }
    }

    public static func lagrangianHessianVectorProduct(
        problem: ConstrainedNonlinearProblem, parameters: [Double],
        constraintWeights: [Double], direction: [Double],
        backend: NonlinearBackend = .swift
    ) throws -> [Double] {
        switch backend {
        case .swift: return try problem.lagrangianHessianVectorProduct(
            parameters: parameters, constraintWeights: constraintWeights, direction: direction)
        case .rust:
            do { return try FFIKernels.evaluateNonlinearLagrangianHessianVectorProduct(
                model: ffi(problem.model), constraints: problem.constraints.map {
                    .init(expression: ffi($0.expression), bound: ffi($0.bound))
                }, parameters: parameters, constraintWeights: constraintWeights,
                direction: direction) }
            catch { throw translate(error) }
        }
    }

    public static func solveSparseKKT(
        problem: SparseKKTProblem, backend: NonlinearBackend = .swift
    ) throws -> SparseKKTResult {
        switch backend {
        case .swift: return try SparseKKTSolver.solve(problem)
        case .rust:
            do {
                let value = try FFIKernels.solveSparseKKT(
                    hessian: .init(dimension: problem.hessian.dimension,
                        rowPointers: problem.hessian.rowPointers,
                        columnIndices: problem.hessian.columnIndices,
                        values: problem.hessian.values),
                    jacobian: .init(rows: problem.jacobian.rows,
                        columns: problem.jacobian.columns,
                        rowPointers: problem.jacobian.rowPointers,
                        columnIndices: problem.jacobian.columnIndices,
                        values: problem.jacobian.values),
                    primalRightHandSide: problem.primalRightHandSide,
                    constraintRightHandSide: problem.constraintRightHandSide,
                    primalRegularization: problem.primalRegularization,
                    dualRegularization: problem.dualRegularization)
                return .init(primal: value.primal, dual: value.dual,
                             residualNorm: value.residualNorm,
                             relativeResidual: value.relativeResidual,
                             factorNonzeros: value.factorNonzeros)
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

    public static func leastSquaresMatrixFree(
        model: NonlinearModel, initial: [Double], weights: [Double] = [],
        loss: RobustLoss = .squared, backend: NonlinearBackend = .swift,
        options: MatrixFreeLeastSquaresOptions = .init()
    ) throws -> MatrixFreeLeastSquaresResult {
        try model.validate()
        switch backend {
        case .swift:
            return try NonlinearLeastSquares.solveMatrixFree(model: model, initial: initial,
                weights: weights, loss: loss, options: options)
        case .rust:
            do {
                let value = try FFIKernels.solveNonlinearLeastSquaresMatrixFree(
                    model: ffi(model), initial: initial, weights: weights, loss: ffi(loss),
                    options: .init(outer: ffi(options.outer),
                        maxKrylovIterations: options.maxKrylovIterations,
                        krylovTolerance: options.krylovTolerance))
                let s = value.solution
                return .init(solution: .init(point: s.point, residuals: s.residuals, cost: s.cost,
                    gradientNorm: s.gradientNorm, iterations: s.iterations,
                    evaluations: s.evaluations, termination: termination(s.termination),
                    finalDamping: s.finalDamping, acceptedSteps: s.acceptedSteps,
                    rejectedSteps: s.rejectedSteps), krylovIterations: value.krylovIterations,
                    jacobianProducts: value.jacobianProducts,
                    transposeJacobianProducts: value.transposeJacobianProducts)
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

    private static func ffi(_ options: NonlinearInteriorPointOptions)
        -> FFINonlinearInteriorPointOptions {
        .init(maxOuterIterations: options.maxOuterIterations,
              maxInnerIterations: options.maxInnerIterations,
              feasibilityTolerance: options.feasibilityTolerance,
              stationarityTolerance: options.stationarityTolerance,
              complementarityTolerance: options.complementarityTolerance,
              initialBarrier: options.initialBarrier,
              barrierReduction: options.barrierReduction,
              minimumBarrier: options.minimumBarrier,
              equalityPenalty: options.equalityPenalty,
              armijo: options.armijo, backtracking: options.backtracking,
              fractionToBoundary: options.fractionToBoundary,
              maxLineSearchIterations: options.maxLineSearchIterations,
              restoration: options.restoration,
              restorationOptions: .init(
                maxIterations: options.restorationOptions.maxIterations,
                feasibilityTolerance: options.restorationOptions.feasibilityTolerance,
                interiorMargin: options.restorationOptions.interiorMargin))
    }

    private static func ffi(_ options: SQPOptions) -> FFISQPOptions {
        .init(
            maxIterations: options.maxIterations,
            feasibilityTolerance: options.feasibilityTolerance,
            stationarityTolerance: options.stationarityTolerance,
            stepTolerance: options.stepTolerance,
            meritPenalty: options.meritPenalty, penaltyIncrease: options.penaltyIncrease,
            armijo: options.armijo, backtracking: options.backtracking,
            maxLineSearchIterations: options.maxLineSearchIterations,
            hessianRegularization: options.hessianRegularization,
            qpMaxIterations: options.qpOptions.maxIterations, qpRho: options.qpOptions.rho,
            qpAbsoluteTolerance: options.qpOptions.absoluteTolerance,
            qpRelativeTolerance: options.qpOptions.relativeTolerance,
            qpConvexityTolerance: options.qpOptions.convexityTolerance,
            restoration: options.restoration,
            restorationOptions: .init(
                maxIterations: options.restorationOptions.maxIterations,
                feasibilityTolerance: options.restorationOptions.feasibilityTolerance,
                interiorMargin: options.restorationOptions.interiorMargin),
            globalization: options.globalization == .merit ? .merit : .filter,
            filterConstraintMargin: options.filterConstraintMargin,
            filterObjectiveMargin: options.filterObjectiveMargin,
            curvature: options.curvature == .bfgs ? .bfgs : .exactLagrangian)
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

    private static func sqpTermination(_ value: FFISQPTermination) -> SQPTermination {
        switch value {
        case .converged: return .converged
        case .iterationLimit: return .iterationLimit
        case .stepLimit: return .stepLimit
        case .lineSearchFailed: return .lineSearchFailed
        case .qpFailure: return .qpFailure
        case .restorationFailed: return .restorationFailed
        case .cancelled: return .cancelled
        }
    }

    private static func interiorPointTermination(
        _ value: FFINonlinearInteriorPointTermination
    ) -> NonlinearInteriorPointTermination {
        switch value {
        case .converged: return .converged
        case .iterationLimit: return .iterationLimit
        case .infeasibleStart: return .infeasibleStart
        case .restorationFailed: return .restorationFailed
        case .lineSearchFailed: return .lineSearchFailed
        case .numericalFailure: return .numericalFailure
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
