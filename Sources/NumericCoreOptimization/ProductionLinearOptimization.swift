import Foundation
import NCBindings

/// Selects the backend used by the audited LP/MILP production pipeline.
public enum ProductionLinearMethod: Sendable, Hashable {
    case automatic, simplex, interiorPoint, branchAndBound
}

public struct ProductionLinearOptions: Sendable, Hashable {
    public var method: ProductionLinearMethod
    public var presolve: ModelPresolveOptions
    public var verificationTolerance: Double

    public init(method: ProductionLinearMethod = .automatic,
                presolve: ModelPresolveOptions = .init(),
                verificationTolerance: Double = 1e-7) {
        self.method = method
        self.presolve = presolve
        self.verificationTolerance = verificationTolerance
    }
}

public struct ProductionLinearDiagnostics: Sendable, Hashable {
    public let finite: Bool
    public let maximumRowViolation: Double
    public let maximumVariableViolation: Double
    public let maximumIntegralityViolation: Double
    public let recomputedObjective: Double
    public let objectiveError: Double

    public func isVerified(tolerance: Double) -> Bool {
        finite && maximumRowViolation <= tolerance && maximumVariableViolation <= tolerance
            && maximumIntegralityViolation <= tolerance && objectiveError <= tolerance
    }
}

public struct ProductionLinearResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let status: FFISolveStatus
    public let diagnostics: ProductionLinearDiagnostics
    public let presolveReport: ModelPresolveReport
    public let originalVariables: Int
    public let reducedVariables: Int
    public let usedMILP: Bool
    public let verified: Bool
}

/// Presolves, solves, postsolves, and independently checks an LP or MILP.
public enum ProductionLinearSolver {
    public static func solve(_ problem: SparseLinearProblem,
                             options: ProductionLinearOptions = .init()) throws
        -> ProductionLinearResult {
        guard options.verificationTolerance.isFinite, options.verificationTolerance >= 0 else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "verification tolerance must be finite and nonnegative")
        }
        let presolved = try LinearModelPresolver.presolve(problem, options: options.presolve)
        let usedMILP = options.method == .branchAndBound
            || (options.method == .automatic && problem.isInteger.contains(true))
        let solution: FFISolution
        switch presolved.status {
        case .infeasible:
            solution = .init(variableValues: [], objectiveValue: 0, status: .infeasible)
        case .solved:
            solution = .init(variableValues: try presolved.restorePoint([]),
                             objectiveValue: presolved.restoreObjective(0), status: .optimal)
        case .reduced:
            guard let reduced = presolved.problem else {
                throw NonlinearOptimizationError.invalidConfiguration("presolve omitted reduced model")
            }
            let reducedSolution: FFISolution
            switch options.method {
            case .automatic where reduced.isInteger.contains(true), .branchAndBound:
                reducedSolution = try SparseLinearSolver.solveMILP(reduced).solution
            case .interiorPoint:
                reducedSolution = try SparseLinearSolver.solveInteriorPoint(reduced)
            default:
                reducedSolution = try SparseLinearSolver.solveSimplex(reduced)
            }
            if reducedSolution.variableValues.isEmpty {
                solution = reducedSolution
            } else {
                solution = .init(
                    variableValues: try presolved.restorePoint(reducedSolution.variableValues),
                    objectiveValue: presolved.restoreObjective(reducedSolution.objectiveValue),
                    status: reducedSolution.status)
            }
        }
        let diagnostics = audit(problem, solution)
        return .init(point: solution.variableValues, objective: solution.objectiveValue,
                     status: solution.status, diagnostics: diagnostics,
                     presolveReport: presolved.report, originalVariables: problem.columns,
                     reducedVariables: presolved.activeVariables.count, usedMILP: usedMILP,
                     verified: solution.status == .optimal
                        && diagnostics.isVerified(tolerance: options.verificationTolerance))
    }

    private static func audit(_ problem: SparseLinearProblem, _ solution: FFISolution)
        -> ProductionLinearDiagnostics {
        let point = solution.variableValues
        guard point.count == problem.columns else {
            return .init(finite: false, maximumRowViolation: .infinity,
                         maximumVariableViolation: .infinity,
                         maximumIntegralityViolation: .infinity,
                         recomputedObjective: .nan, objectiveError: .infinity)
        }
        var activities = [Double](repeating: 0, count: problem.rows)
        for row in 0..<problem.rows {
            for index in problem.rowPointers[row]..<problem.rowPointers[row + 1] {
                activities[row] += problem.values[index] * point[problem.columnIndices[index]]
            }
        }
        func violation(_ value: Double, _ bound: ParameterBound) -> Double {
            max(0, (bound.lower.map { $0 - value } ?? 0),
                (bound.upper.map { value - $0 } ?? 0))
        }
        let rowViolation = zip(activities, problem.rowBounds)
            .map(violation).max() ?? 0
        let variableViolation = zip(point, problem.variableBounds)
            .map(violation).max() ?? 0
        let integralityViolation = point.indices.filter { problem.isInteger[$0] }
            .map { abs(point[$0] - point[$0].rounded()) }.max() ?? 0
        let objective = zip(problem.objective, point).reduce(0) { $0 + $1.0 * $1.1 }
        let finite = point.allSatisfy(\.isFinite) && solution.objectiveValue.isFinite
            && activities.allSatisfy(\.isFinite) && objective.isFinite
        return .init(finite: finite, maximumRowViolation: rowViolation,
                     maximumVariableViolation: variableViolation,
                     maximumIntegralityViolation: integralityViolation,
                     recomputedObjective: objective,
                     objectiveError: abs(objective - solution.objectiveValue))
    }
}
