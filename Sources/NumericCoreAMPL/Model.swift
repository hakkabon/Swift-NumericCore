import Foundation
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
///    produces an LP/MILP `CompiledProblem`; `compileNonlinear()` lowers an
///    algebraic expression tree to the shared `NonlinearModel` graph.
/// 3. **Solver interface** — linear models call `nc-optimize` through
///    `NCBindings`; nonlinear models select the Swift or Rust implementation
///    through `NumericCoreOptimization`.
/// 4. **Solvers themselves** — remain outside this modeling target.
///
/// `Model` is the seam between (1) and (2): the parser only ever calls
/// `Model`'s builder methods (`addVariable`/`addParameter`/
/// builder methods, never touches a compiled problem directly, and neither
/// compiler touches lexer/parser types.
public struct Model {
    public private(set) var variableNames: [String] = []
    public private(set) var variableBounds: [(lower: Double?, upper: Double?)] = []
    public private(set) var variableIsInteger: [Bool] = []
    public private(set) var parameterValues: [String: Double] = [:]
    public private(set) var constraints: [Constraint] = []
    public private(set) var objective: Objective?

    public init() {}

    /// Declare a variable. Returns its index for use in
    /// `addConstraint`/`setObjective`. Named, rather than positional-only,
    /// because AMPL models are written with named variables and the
    /// eventual parser output should map directly onto this.
    ///
    /// `isInteger` restricts this variable to integer values when
    /// solved via `.solve(using: .branchAndBound)` — ignored entirely
    /// by `.simplex`/`.interiorPoint`, which always solve the LP
    /// relaxation regardless. Mirrors `nc_optimize::Problem::is_integer`
    /// (Rust side) — see that field's doc comment.
    @discardableResult
    public mutating func addVariable(
        _ name: String,
        lowerBound: Double? = 0,
        upperBound: Double? = nil,
        isInteger: Bool = false
    ) -> Int {
        variableNames.append(name)
        variableBounds.append((lowerBound, upperBound))
        variableIsInteger.append(isInteger)
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

    @discardableResult
    public mutating func addNonlinearConstraint(
        name: String, lhs: AlgebraicExpression,
        relation: RelationalOperator, rhs: AlgebraicExpression
    ) -> Int {
        constraints.append(Constraint(
            name: name, lhs: lhs.affine ?? .init(), relation: relation,
            rhs: rhs.affine ?? .init(), algebraicLHS: lhs, algebraicRHS: rhs))
        return constraints.count - 1
    }

    /// Sets the model's objective. A `Model` has at most one objective —
    /// calling this again replaces the previous one, matching how a
    /// single AMPL model declares exactly one `minimize`/`maximize`
    /// statement in this grammar subset (see `docs/design/ampl-grammar.md`;
    /// multiple named objectives are out of scope for this subset).
    public mutating func setObjective(name: String, sense: ObjectiveSense, expression: LinearExpression) {
        objective = Objective(name: name, sense: sense, expression: expression)
    }

    public mutating func setNonlinearObjective(
        name: String, sense: ObjectiveSense, expression: AlgebraicExpression
    ) {
        objective = Objective(
            name: name, sense: sense, expression: expression.affine ?? .init(),
            algebraicExpression: expression)
    }
}

/// Unindexed scalar expression used by the nonlinear AMPL subset. Parameters
/// are folded to constants during parsing; variables retain source-model order.
public indirect enum AlgebraicExpression: Sendable, Hashable {
    case constant(Double)
    case variable(Int)
    case add(Self, Self), subtract(Self, Self), multiply(Self, Self), divide(Self, Self)
    case negate(Self), power(Self, Double)
    case exp(Self), log(Self), sqrt(Self), sin(Self), cos(Self)

    /// Returns an affine representation when possible, preserving the existing
    /// LP/MILP compilation path for input accepted by the original grammar.
    public var affine: LinearExpression? {
        switch self {
        case .constant(let value):
            var result = LinearExpression(); result.add(constant: value); return result
        case .variable(let index):
            var result = LinearExpression(); result.add(coefficient: 1, variableIndex: index); return result
        case .add(let lhs, let rhs): return combine(lhs, rhs, rhsScale: 1)
        case .subtract(let lhs, let rhs): return combine(lhs, rhs, rhsScale: -1)
        case .negate(let value): return value.affine.map { scaled($0, by: -1) }
        case .multiply(let lhs, let rhs):
            if let scalar = lhs.constantValue { return rhs.affine.map { scaled($0, by: scalar) } }
            if let scalar = rhs.constantValue { return lhs.affine.map { scaled($0, by: scalar) } }
            return nil
        case .divide(let lhs, let rhs):
            guard let scalar = rhs.constantValue, scalar != 0 else { return nil }
            return lhs.affine.map { scaled($0, by: 1 / scalar) }
        case .power(let value, let exponent):
            if exponent == 1 { return value.affine }
            if exponent == 0 {
                var result = LinearExpression(); result.add(constant: 1); return result
            }
            if let constant = constantValue {
                var result = LinearExpression(); result.add(constant: constant); return result
            }
            return nil
        case .exp, .log, .sqrt, .sin, .cos:
            guard let constant = constantValue else { return nil }
            var result = LinearExpression(); result.add(constant: constant); return result
        }
    }

    private var constantValue: Double? {
        switch self {
        case .constant(let value): return value
        case .variable: return nil
        case .add(let lhs, let rhs): return zipConstants(lhs, rhs, +)
        case .subtract(let lhs, let rhs): return zipConstants(lhs, rhs, -)
        case .multiply(let lhs, let rhs): return zipConstants(lhs, rhs, *)
        case .divide(let lhs, let rhs): return zipConstants(lhs, rhs, /)
        case .negate(let value): return value.constantValue.map(-)
        case .power(let value, let exponent):
            return value.constantValue.map { Foundation.pow($0, exponent) }
        case .exp(let value): return value.constantValue.map(Foundation.exp)
        case .log(let value): return value.constantValue.map(Foundation.log)
        case .sqrt(let value): return value.constantValue.map(Foundation.sqrt)
        case .sin(let value): return value.constantValue.map(Foundation.sin)
        case .cos(let value): return value.constantValue.map(Foundation.cos)
        }
    }

    private func zipConstants(_ lhs: Self, _ rhs: Self,
                              _ operation: (Double, Double) -> Double) -> Double? {
        guard let left = lhs.constantValue, let right = rhs.constantValue else { return nil }
        return operation(left, right)
    }

    private func combine(_ lhs: Self, _ rhs: Self, rhsScale: Double) -> LinearExpression? {
        guard var result = lhs.affine, let other = rhs.affine else { return nil }
        result.add(constant: rhsScale * other.constant)
        for (index, coefficient) in other.coefficients {
            result.add(coefficient: rhsScale * coefficient, variableIndex: index)
        }
        return result
    }

    private func scaled(_ expression: LinearExpression, by scalar: Double) -> LinearExpression {
        var result = LinearExpression(); result.add(constant: scalar * expression.constant)
        for (index, coefficient) in expression.coefficients {
            result.add(coefficient: scalar * coefficient, variableIndex: index)
        }
        return result
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
    public let algebraicLHS: AlgebraicExpression?
    public let algebraicRHS: AlgebraicExpression?

    public init(name: String, lhs: LinearExpression, relation: RelationalOperator,
                rhs: LinearExpression, algebraicLHS: AlgebraicExpression? = nil,
                algebraicRHS: AlgebraicExpression? = nil) {
        self.name = name; self.lhs = lhs; self.relation = relation; self.rhs = rhs
        self.algebraicLHS = algebraicLHS; self.algebraicRHS = algebraicRHS
    }
}

public enum ObjectiveSense: Equatable {
    case minimize
    case maximize
}

public struct Objective {
    public let name: String
    public let sense: ObjectiveSense
    public let expression: LinearExpression
    public let algebraicExpression: AlgebraicExpression?

    public init(name: String, sense: ObjectiveSense, expression: LinearExpression,
                algebraicExpression: AlgebraicExpression? = nil) {
        self.name = name; self.sense = sense; self.expression = expression
        self.algebraicExpression = algebraicExpression
    }
}

/// A `Model` after presolve — ready to hand to `nc-optimize::Solver` via
/// `NCBindings`. Field shape intentionally mirrors `nc_optimize::Problem`
/// (Rust) so the eventual FFI call is closer to a direct translation than
/// a redesign. Produced by `Model.compile()` (see `Presolve.swift`).
public struct CompiledProblem {
    /// Stable source-model order used by `LPSolution.variableValuesByName`.
    public let variableNames: [String]
    /// Always in minimize form — a `maximize` objective has already had
    /// its coefficients negated (see `objectiveSign`).
    public let objective: Vector<Double>
    public let constraints: SparseMatrix<Double>
    public let variableLowerBounds: [Double?]
    public let variableUpperBounds: [Double?]
    public let rowBounds: [(lower: Double?, upper: Double?)]
    /// Per-variable integer restriction, for `.solve(using: .branchAndBound)`.
    /// Ignored by `.simplex`/`.interiorPoint`.
    public let variableIsInteger: [Bool]

    /// `+1` if the original objective was `minimize`, `-1` if
    /// `maximize`. Multiply a solver's returned objective value by this
    /// to report it in the model's original (possibly `maximize`) sense
    /// — see `docs/design/ampl-grammar.md`'s worked example.
    public let objectiveSign: Double
    /// Constant term from the source objective, omitted from the numerical
    /// coefficient vector but restored in public objective reporting.
    public let objectiveConstant: Double
}
