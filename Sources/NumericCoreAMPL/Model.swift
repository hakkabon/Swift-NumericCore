import NumericCore
import NumericCoreSparse

/// AMPL-style declarative modeling language.
///
/// This module is the largest piece of unbuilt scope in the project —
/// see the sequencing decision in `docs/decisions/0004-optimize-sequencing.md`.
/// It decomposes into four subsystems, deliberately kept as separate
/// files/types even at this early stage so each can be built and tested
/// independently:
///
/// 1. **Modeling language + parser** (`ModelAST.swift`, not yet written) —
///    sets, parameters, variables, constraints, objectives. Intended to
///    be built on the existing Grammar/Lexer/Parser Swift packages
///    (`hakkabon/Grammar`, `hakkabon/Parser`, `hakkabon/Lexer`) rather
///    than a bespoke parser — this is where that ecosystem's investment
///    pays off directly. Uncomment the package dependencies in
///    `Package.swift` once this is scheduled.
/// 2. **Presolve / symbolic-to-numeric translation** (`Presolve.swift`,
///    not yet written) — turns a `Model` (sets resolved, expressions
///    flattened) into an `nc_optimize.Problem`: a dense objective vector,
///    a `SparseMatrix` constraint matrix, and row/variable bounds.
/// 3. **Solver interface** — this is `nc-optimize::Solver` (Rust side),
///    not duplicated here. `NumericCoreAMPL` calls through to it via
///    `NCBindings` once the FFI surface exists.
/// 4. **Solvers themselves** — live in `nc-optimize` (Rust), not here.
///    This module never implements simplex/branch-and-bound/interior-point
///    directly; it only produces the `Problem` those solvers consume.
///
/// Nothing below `ModelBuilder` is real yet. It exists to fix the shape
/// of the public API early — a `Model` built up declaratively, compiled
/// to a `CompiledProblem` wrapping a `SparseMatrix`-backed constraint
/// matrix — so the parser (once built) has a concrete target to compile
/// into, and the presolve layer has a concrete input to consume.
public struct Model {
    public private(set) var variableNames: [String] = []
    public private(set) var variableBounds: [(lower: Double?, upper: Double?)] = []

    public init() {}

    /// Declare a variable. Returns its index for use in
    /// `addConstraint`/`setObjective`. Named, rather than positional-only,
    /// because AMPL models are written with named variables and the
    /// eventual parser output should map directly onto this.
    @discardableResult
    public mutating func addVariable(
        _ name: String,
        lowerBound: Double? = 0,
        upperBound: Double? = nil
    ) -> Int {
        variableNames.append(name)
        variableBounds.append((lowerBound, upperBound))
        return variableNames.count - 1
    }
}

/// A `Model` after presolve — ready to hand to `nc-optimize::Solver` via
/// `NCBindings`. Field shape intentionally mirrors `nc_optimize::Problem`
/// (Rust) so the eventual FFI call is closer to a direct translation than
/// a redesign.
public struct CompiledProblem {
    public let objective: Vector<Double>
    public let constraints: SparseMatrix<Double>
    public let variableLowerBounds: [Double?]
    public let variableUpperBounds: [Double?]
}
