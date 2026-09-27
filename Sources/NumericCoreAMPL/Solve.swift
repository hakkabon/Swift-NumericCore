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
    /// Already corrected for the model's original objective sense —
    /// see `CompiledProblem.objectiveSign`'s doc comment. A `maximize`
    /// model's solution reports the actual (positive-sense) maximum
    /// here, not the negated internal minimize-form value.
    public let objectiveValue: Double
    public let status: LPSolveStatus
}

extension CompiledProblem {
    /// Solves this presolved problem via the chosen `nc-optimize`
    /// solver, crossing the FFI boundary via `NCBindings`. This is the
    /// step `docs/design/ampl-grammar.md`'s "Next steps" listed as not
    /// yet done — `AMPLParser.parse(_:)` → `Model.compile()` → here is
    /// a complete path from AMPL source text to an actual solved LP or
    /// MILP (the latter via `.branchAndBound`, once a model declares an
    /// `integer` variable).
    public func solve(using solver: LPSolverKind = .simplex) throws -> LPSolution {
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

        return LPSolution(
            variableValues: result.variableValues,
            objectiveValue: result.objectiveValue * objectiveSign,
            status: status
        )
    }
}
