import NCBindings
import NumericCore
import NumericCoreSparse

/// Which of `nc-optimize`'s solvers to use — explicit, not
/// policy-based (per the explicit-solver-selection decision from the
/// simplex-vs-interior-point scoping discussion; see `Rust-NumericCore`'s
/// ADR 0004 update). Despite the name (kept for continuity with
/// existing callers rather than renamed to `SolverKind`), this now
/// covers MILP too via `.branchAndBound`.
public enum LPSolverKind {
    /// Uses branch-and-bound when any variable is integer-restricted;
    /// otherwise uses revised simplex. This is the safe default.
    case automatic
    /// `nc-optimize::RevisedSimplexSolver`. Handles equality constraints
    /// and fixed variables; rigorous (not heuristic) infeasibility and
    /// unboundedness detection. Prefer this unless the problem is large
    /// enough that interior-point's better scaling matters.
    case simplex
    /// `nc-optimize::InteriorPointSolver`. Rejects equality-constrained
    /// rows and fixed variables outright (throws — see that solver's
    /// Rust-side module docs); unboundedness detection is heuristic,
    /// not certificate-based.
    case interiorPoint
    /// `nc-optimize::BranchAndBoundSolver` — LP-relaxation
    /// branch-and-bound, the only option that honors
    /// `Model.addVariable(_:isInteger:)`/the AMPL grammar's `integer`
    /// qualifier. `.simplex`/`.interiorPoint` both ignore integrality
    /// entirely and solve the LP relaxation regardless — pick this one
    /// whenever the model actually declared an integer variable.
    case branchAndBound
}

public enum LPSolveStatus: Equatable {
    case optimal
    case infeasible
    case unbounded
    case iterationLimit
}

public struct LPSolution {
    public let variableValues: [Double]
    /// Values keyed by the source model's variable names.
    public let variableValuesByName: [String: Double]
    /// Already corrected for the model's original objective sense —
    /// see `CompiledProblem.objectiveSign`'s doc comment. A `maximize`
    /// model's solution reports the actual (positive-sense) maximum
    /// here, not the negated internal minimize-form value.
    public let objectiveValue: Double
    public let status: LPSolveStatus
    /// Independently recomputed from the compiled problem and returned
    /// variables, rather than copied from the solver's internal state.
    public let diagnostics: OptimizationSolutionDiagnostics

    /// True only for an optimal status whose independently recomputed
    /// feasibility, integrality, and objective checks all pass.
    public func isVerified(tolerance: Double) -> Bool {
        status == .optimal && diagnostics.isVerified(tolerance: tolerance)
    }
}

public struct OptimizationSolutionDiagnostics: Sendable, Hashable {
    public let finite: Bool
    public let maximumRowViolation: Double
    public let maximumVariableBoundViolation: Double
    public let maximumIntegralityViolation: Double
    public let recomputedObjectiveValue: Double
    public let objectiveError: Double

    public func isVerified(tolerance: Double) -> Bool {
        tolerance.isFinite && tolerance >= 0 && finite
            && maximumRowViolation <= tolerance
            && maximumVariableBoundViolation <= tolerance
            && maximumIntegralityViolation <= tolerance
            && objectiveError <= tolerance
    }
}

extension CompiledProblem {
    /// Solves this presolved problem via the chosen `nc-optimize`
    /// solver, crossing the FFI boundary via `NCBindings`. This is the
    /// step `docs/design/ampl-grammar.md`'s "Next steps" listed as not
    /// yet done — `AMPLParser.parse(_:)` → `Model.compile()` → here is
    /// a complete path from AMPL source text to an actual solved LP or
    /// MILP (the latter via `.branchAndBound`, once a model declares an
    /// `integer` variable).
    public func solve(using solver: LPSolverKind = .automatic) throws -> LPSolution {
        let ffiProblem = FFIProblem(
            objective: objective.storage,
            constraintRows: constraints.rows,
            constraintCols: constraints.cols,
            constraintRowPointers: constraints.csrRowPointers,
            constraintColumnIndices: constraints.csrColumnIndices,
            constraintValues: constraints.csrValues,
            rowBounds: rowBounds.map { FFIBound(lower: $0.lower, upper: $0.upper) },
            varBounds: zip(variableLowerBounds, variableUpperBounds).map { FFIBound(lower: $0.0, upper: $0.1) },
            isInteger: variableIsInteger
        )

        let result: FFISolution
        switch solver {
        case .automatic:
            result = try variableIsInteger.contains(true)
                ? FFIKernels.solveMILP(ffiProblem)
                : FFIKernels.solveLPSimplex(ffiProblem)
        case .simplex:
            result = try FFIKernels.solveLPSimplex(ffiProblem)
        case .interiorPoint:
            result = try FFIKernels.solveLPInteriorPoint(ffiProblem)
        case .branchAndBound:
            result = try FFIKernels.solveMILP(ffiProblem)
        }

        let status: LPSolveStatus
        switch result.status {
        case .optimal: status = .optimal
        case .infeasible: status = .infeasible
        case .unbounded: status = .unbounded
        case .iterationLimit: status = .iterationLimit
        }

        let correctedObjective = result.objectiveValue * objectiveSign + objectiveConstant
        let values = result.variableValues
        return LPSolution(
            variableValues: values,
            variableValuesByName: Dictionary(
                uniqueKeysWithValues: zip(variableNames, values)
            ),
            objectiveValue: correctedObjective,
            status: status,
            diagnostics: solutionDiagnostics(
                values: values, reportedObjective: correctedObjective
            )
        )
    }

    private func solutionDiagnostics(
        values: [Double], reportedObjective: Double
    ) -> OptimizationSolutionDiagnostics {
        guard values.count == objective.count,
              variableLowerBounds.count == objective.count,
              variableUpperBounds.count == objective.count,
              variableIsInteger.count == objective.count,
              rowBounds.count == constraints.rows,
              constraints.cols == objective.count
        else {
            return OptimizationSolutionDiagnostics(
                finite: false,
                maximumRowViolation: .infinity,
                maximumVariableBoundViolation: .infinity,
                maximumIntegralityViolation: .infinity,
                recomputedObjectiveValue: .nan,
                objectiveError: .infinity
            )
        }

        var rowValues = [Double](repeating: 0, count: constraints.rows)
        let rowPointers = constraints.csrRowPointers
        let columns = constraints.csrColumnIndices
        let coefficients = constraints.csrValues
        for row in 0..<constraints.rows {
            for index in rowPointers[row]..<rowPointers[row + 1] {
                rowValues[row] += coefficients[index] * values[columns[index]]
            }
        }

        let rowViolation = zip(rowValues, rowBounds).reduce(0.0) {
            max($0, Self.boundViolation(value: $1.0, lower: $1.1.lower, upper: $1.1.upper))
        }
        let variableViolation = values.indices.reduce(0.0) { partial, index in
            max(partial, Self.boundViolation(
                value: values[index], lower: variableLowerBounds[index],
                upper: variableUpperBounds[index]
            ))
        }
        let integralityViolation = values.indices.reduce(0.0) { partial, index in
            guard variableIsInteger[index] else { return partial }
            return max(partial, abs(values[index] - values[index].rounded()))
        }
        // The compiled objective is always minimization form. Convert it back
        // to the source model's sense before comparing with the public result.
        let recomputedObjective = zip(objective.storage, values)
            .reduce(0.0) { $0 + $1.0 * $1.1 } * objectiveSign + objectiveConstant
        let objectiveError = abs(reportedObjective - recomputedObjective)
        let finite = values.allSatisfy(\.isFinite) && rowValues.allSatisfy(\.isFinite)
            && reportedObjective.isFinite && recomputedObjective.isFinite
            && rowViolation.isFinite && variableViolation.isFinite
            && integralityViolation.isFinite && objectiveError.isFinite

        return OptimizationSolutionDiagnostics(
            finite: finite,
            maximumRowViolation: rowViolation,
            maximumVariableBoundViolation: variableViolation,
            maximumIntegralityViolation: integralityViolation,
            recomputedObjectiveValue: recomputedObjective,
            objectiveError: objectiveError
        )
    }

    private static func boundViolation(
        value: Double, lower: Double?, upper: Double?
    ) -> Double {
        max(lower.map { max($0 - value, 0) } ?? 0,
            upper.map { max(value - $0, 0) } ?? 0)
    }
}
