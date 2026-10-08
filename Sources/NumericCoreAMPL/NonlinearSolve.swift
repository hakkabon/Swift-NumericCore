import NumericCoreOptimization

public enum NonlinearSolveConfiguration: Sendable, Hashable {
    case automatic(backend: NonlinearBackend)
    case boundedLBFGS(backend: NonlinearBackend, options: LBFGSOptions)
    case sqp(backend: NonlinearBackend, options: SQPOptions)
    case augmentedLagrangian(backend: NonlinearBackend, options: ConstrainedOptions)
    case mixedInteger(backend: NonlinearBackend, options: MixedIntegerNonlinearOptions)

    public static var `default`: Self { .automatic(backend: .swift) }
}

public enum NonlinearAMPLSolveStatus: Sendable, Hashable {
    case converged, iterationLimit, stepLimit, lineSearchFailed
    case qpFailure, penaltyLimit, cancelled
    case searchExhausted, localGapLimit, nodeLimit, infeasible, relaxationFailure
}

public struct NonlinearAMPLSolution: Sendable, Hashable {
    public let variableValues: [Double]
    public let variableValuesByName: [String: Double]
    /// Reported in the source model's minimize/maximize sense.
    public let objectiveValue: Double
    /// Values of `lhs - rhs`, keyed in source constraint order.
    public let constraintValues: [Double]
    public let constraintValuesByName: [String: Double]
    public let multipliers: [ConstraintMultiplier]
    public let maximumViolation: Double
    public let stationarityNorm: Double
    public let iterations: Int
    public let evaluations: Int
    public let status: NonlinearAMPLSolveStatus
    public let nodesExplored: Int
    public let globalOptimalityCertified: Bool

    public func isVerified(feasibilityTolerance: Double,
                           stationarityTolerance: Double) -> Bool {
        status == .converged && feasibilityTolerance.isFinite
            && stationarityTolerance.isFinite && feasibilityTolerance >= 0
            && stationarityTolerance >= 0 && variableValues.allSatisfy(\.isFinite)
            && objectiveValue.isFinite && maximumViolation <= feasibilityTolerance
            && stationarityNorm <= stationarityTolerance
    }
}

public extension CompiledNonlinearProblem {
    func solve(initial: [Double]? = nil,
               configuration: NonlinearSolveConfiguration = .default) throws
        -> NonlinearAMPLSolution {
        let start = initial ?? defaultInitialPoint
        switch configuration {
        case .automatic(let backend):
            if isInteger.contains(true) {
                return try solve(initial: start, configuration: .mixedInteger(
                    backend: backend, options: .init()))
            }
            if constraints.isEmpty {
                return try solve(initial: start, configuration: .boundedLBFGS(
                    backend: backend, options: .init()))
            }
            return try solve(initial: start, configuration: .sqp(
                backend: backend, options: .init()))
        case .boundedLBFGS(let backend, let options):
            guard constraints.isEmpty else { throw NonlinearPresolveError.constraintsRequired }
            let result = try NonlinearModelSolver.minimize(
                model: model, initial: start, backend: backend, options: options)
            return solution(
                point: result.point, objective: result.objective, values: [], multipliers: [],
                violation: 0, stationarity: result.gradientNorm,
                iterations: result.iterations, evaluations: result.evaluations,
                status: status(result.termination))
        case .sqp(let backend, let options):
            let problem = try constrainedProblem()
            let result = try NonlinearModelSolver.minimizeSQP(
                problem: problem, initial: start, backend: backend, options: options)
            return solution(
                point: result.point, objective: result.objective,
                values: result.constraintValues, multipliers: result.multipliers,
                violation: result.maximumViolation, stationarity: result.stationarityNorm,
                iterations: result.iterations, evaluations: result.evaluations,
                status: status(result.termination))
        case .augmentedLagrangian(let backend, let options):
            let problem = try constrainedProblem()
            let result = try NonlinearModelSolver.minimize(
                problem: problem, initial: start, backend: backend, options: options)
            return solution(
                point: result.point, objective: result.objective,
                values: result.constraintValues, multipliers: result.multipliers,
                violation: result.maximumViolation, stationarity: result.stationarityNorm,
                iterations: result.outerIterations, evaluations: result.evaluations,
                status: status(result.termination))
        case .mixedInteger(let backend, let options):
            let problem = try MixedIntegerNonlinearProblem(
                model: model, constraints: constraints, isInteger: isInteger)
            let result = try NonlinearModelSolver.minimizeMixedInteger(
                problem: problem, initial: start, backend: backend, options: options)
            return solution(
                point: result.point, objective: result.objective,
                values: result.constraintValues, multipliers: result.multipliers,
                violation: result.maximumViolation, stationarity: result.stationarityNorm,
                iterations: result.nodesExplored, evaluations: result.relaxationsSolved,
                status: status(result.termination), nodesExplored: result.nodesExplored,
                globalOptimalityCertified: result.globalOptimalityCertified)
        }
    }

    private func constrainedProblem() throws -> ConstrainedNonlinearProblem {
        guard !constraints.isEmpty else { throw NonlinearPresolveError.constraintsRequired }
        return try .init(model: model, constraints: constraints)
    }

    private func solution(
        point: [Double], objective: Double, values: [Double],
        multipliers: [ConstraintMultiplier], violation: Double,
        stationarity: Double, iterations: Int, evaluations: Int,
        status: NonlinearAMPLSolveStatus, nodesExplored: Int = 0,
        globalOptimalityCertified: Bool = false
    ) -> NonlinearAMPLSolution {
        .init(
            variableValues: point,
            variableValuesByName: Dictionary(uniqueKeysWithValues: zip(variableNames, point)),
            objectiveValue: objectiveSign * objective,
            constraintValues: values,
            constraintValuesByName: Dictionary(
                uniqueKeysWithValues: zip(constraintNames, values)),
            multipliers: multipliers, maximumViolation: violation,
            stationarityNorm: stationarity, iterations: iterations,
            evaluations: evaluations, status: status, nodesExplored: nodesExplored,
            globalOptimalityCertified: globalOptimalityCertified)
    }

    private func status(_ value: SQPTermination) -> NonlinearAMPLSolveStatus {
        switch value {
        case .converged: return .converged
        case .iterationLimit: return .iterationLimit
        case .stepLimit: return .stepLimit
        case .lineSearchFailed: return .lineSearchFailed
        case .qpFailure: return .qpFailure
        case .cancelled: return .cancelled
        }
    }

    private func status(_ value: ConstrainedTermination) -> NonlinearAMPLSolveStatus {
        switch value {
        case .converged: return .converged
        case .iterationLimit: return .iterationLimit
        case .penaltyLimit: return .penaltyLimit
        case .cancelled: return .cancelled
        }
    }


    private func status(_ value: NonlinearTermination) -> NonlinearAMPLSolveStatus {
        switch value {
        case .convergedGradient, .convergedStep, .convergedObjective: return .converged
        case .iterationLimit: return .iterationLimit
        case .lineSearchFailed, .dampingLimit: return .lineSearchFailed
        case .cancelled: return .cancelled
        }
    }

    private func status(_ value: MixedIntegerNonlinearTermination)
        -> NonlinearAMPLSolveStatus {
        switch value {
        case .searchExhausted: return .searchExhausted
        case .localGapLimit: return .localGapLimit
        case .nodeLimit: return .nodeLimit
        case .infeasible: return .infeasible
        case .relaxationFailure: return .relaxationFailure
        case .cancelled: return .cancelled
        }
    }
}
