import NumericCore
import NumericCoreSparse

/// AMPL-style declarative modeling language.
///
/// This module decomposes into four subsystems, per the sequencing
/// decision in `docs/decisions/0004-optimize-sequencing.md`:
///
/// 1. **Modeling language + parser** — `AMPLLexer.swift`/`AMPLParser.swift`,
///    implementing the grammar in `docs/design/ampl-grammar.md`. This is
///    a **hand-rolled recursive-descent parser**, not yet built on the
///    `hakkabon/Grammar`/`Parser`/`Lexer` Swift packages the original
///    design sketch called for — their exact public APIs weren't
///    available to write against, so a small self-contained
///    implementation was chosen over guessing at an external API (the
///    same reasoning as `NCBindings/FFIBridge.swift`'s stance on not
///    guessing at things that can be gotten wrong silently). Migrating
///    to those packages later is a real option once their APIs are in
///    hand — the target either way is `Model`'s builder methods below,
///    so the migration is isolated to these two files.
/// 2. **Presolve / symbolic-to-numeric translation** — `Model.compile()`
///    in `Presolve.swift`, turning a `Model` into a `CompiledProblem`.
/// 3. **Solver interface** — `nc-optimize::Solver` (Rust side), not
///    duplicated here. `NumericCoreAMPL` calls through to it via
///    `NCBindings` once that call-through is wired (not yet).
/// 4. **Solvers themselves** — live in `nc-optimize` (Rust), not here.
///
/// `Model` is the seam between (1) and (2): the parser only ever calls
/// `Model`'s builder methods (`addVariable`/`addParameter`/
/// `addConstraint`/`setObjective`), never touches `CompiledProblem`
/// directly, and `compile()` never touches lexer/parser types.
public struct Model {
    public private(set) var variableNames: [String] = []
    public private(set) var variableBounds: [(lower: Double?, upper: Double?)] = []
    public private(set) var parameterValues: [String: Double] = [:]
    public private(set) var constraints: [Constraint] = []
    public private(set) var objective: Objective?

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

    /// Look up a previously-declared variable's index by name, or `nil`
    /// if no variable with that name has been declared. Used by
    /// `AMPLParser` to resolve identifiers appearing in expressions.
    public func variableIndex(named name: String) -> Int? {
        variableNames.firstIndex(of: name)
    }

    /// A named scalar constant — AMPL's `param`. Declared separately
    /// from variables since a param contributes a constant (folded at
    /// parse time), never a linear coefficient on an unknown.
    public mutating func addParameter(_ name: String, value: Double) {
        parameterValues[name] = value
    }

    @discardableResult
    public mutating func addConstraint(
        name: String,
        lhs: LinearExpression,
        relation: RelationalOperator,
        rhs: LinearExpression
    ) -> Int {
        constraints.append(Constraint(name: name, lhs: lhs, relation: relation, rhs: rhs))
        return constraints.count - 1
    }

    /// Sets the model's objective. A `Model` has at most one objective —
    /// calling this again replaces the previous one, matching how a
    /// single AMPL model declares exactly one `minimize`/`maximize`
    /// statement in this grammar subset (see `docs/design/ampl-grammar.md`;
    /// multiple named objectives are out of scope for the flat LP subset).
    public mutating func setObjective(name: String, sense: ObjectiveSense, expression: LinearExpression) {
        objective = Objective(name: name, sense: sense, expression: expression)
    }
}

/// A linear combination of variables plus a constant offset —
/// `docs/design/ampl-grammar.md`'s `linear_expr` production, after
/// identifiers have been resolved to either a variable index (becomes a
/// coefficient) or a parameter (folds into `constant` at parse time).
public struct LinearExpression {
    /// Variable index → summed coefficient. A `Dictionary` rather than
    /// a dense `[Double]` since expressions are built incrementally by
    /// the parser and are typically sparse (an AMPL constraint rarely
    /// touches every variable in the model) — density only matters once
    /// `Model.compile()` builds the final sparse constraint matrix.
    public private(set) var coefficients: [Int: Double] = [:]
    public private(set) var constant: Double = 0

    public init() {}

    public mutating func add(coefficient: Double, variableIndex: Int) {
        coefficients[variableIndex, default: 0] += coefficient
    }

    public mutating func add(constant: Double) {
        self.constant += constant
    }
}

public enum RelationalOperator: Equatable {
    case lessThanOrEqual
    case greaterThanOrEqual
    case equal
}

public struct Constraint {
    public let name: String
    public let lhs: LinearExpression
    public let relation: RelationalOperator
    public let rhs: LinearExpression
}

public enum ObjectiveSense: Equatable {
    case minimize
    case maximize
}

public struct Objective {
    public let name: String
    public let sense: ObjectiveSense
    public let expression: LinearExpression
}

/// A `Model` after presolve — ready to hand to `nc-optimize::Solver` via
/// `NCBindings`. Field shape intentionally mirrors `nc_optimize::Problem`
/// (Rust) so the eventual FFI call is closer to a direct translation than
/// a redesign. Produced by `Model.compile()` (see `Presolve.swift`).
public struct CompiledProblem {
    /// Always in minimize form — a `maximize` objective has already had
    /// its coefficients negated (see `objectiveSign`).
    public let objective: Vector<Double>
    public let constraints: SparseMatrix<Double>
    public let variableLowerBounds: [Double?]
    public let variableUpperBounds: [Double?]
    public let rowBounds: [(lower: Double?, upper: Double?)]

    /// `+1` if the original objective was `minimize`, `-1` if
    /// `maximize`. Multiply a solver's returned objective value by this
    /// to report it in the model's original (possibly `maximize`) sense
    /// — see `docs/design/ampl-grammar.md`'s worked example.
    public let objectiveSign: Double
}
