/// Parser errors. Each case carries the token position `AMPLLexer`
/// recorded, so a caller can point at the offending source location.
public enum AMPLParseError: Error, Equatable {
    case unexpectedToken(expected: String, found: String, position: Int)
    case unknownIdentifier(String, position: Int)
    case lexError(LexError)
}

/// Recursive-descent parser for the grammar in
/// `docs/design/ampl-grammar.md`. See `Model.swift`'s module docs for
/// why this is hand-rolled rather than built on `hakkabon/Parser`.
///
/// Algebraic expressions use ordinary arithmetic precedence, unary signs,
/// parentheses, constant powers, and the elementary functions documented by
/// the grammar. AMPL's coefficient notation (`3 x`) is treated as implicit
/// multiplication, preserving compatibility with the original affine subset.
public enum AMPLParser {
    public static func parse(_ source: String) throws -> Model {
        let tokens: [Token]
        do {
            tokens = try AMPLLexer.tokenize(source)
        } catch let error as LexError {
            throw AMPLParseError.lexError(error)
        }
        var state = ParserState(tokens: tokens)
        return try state.parseModel()
    }
}

private struct ParserState {
    let tokens: [Token]
    var index = 0
    var model = Model()

    var current: Token { tokens[index] }

    mutating func advance() -> Token {
        let token = tokens[index]
        if case .endOfInput = token.kind {
            // Stay put at end-of-input rather than running off the
            // array — every caller checks for .endOfInput before
            // relying on further advances, but this keeps `advance()`
            // itself safe regardless.
        } else {
            index += 1
        }
        return token
    }

    func describe(_ kind: TokenKind) -> String {
        switch kind {
        case .keyword(let k): return "keyword '\(k)'"
        case .identifier(let name): return "identifier '\(name)'"
        case .number(let n): return "number '\(n)'"
        case .symbol(let s): return "'\(s)'"
        case .endOfInput: return "end of input"
        }
    }

    mutating func expectKeyword(_ keyword: String) throws {
        guard current.kind == .keyword(keyword) else {
            throw AMPLParseError.unexpectedToken(
                expected: "keyword '\(keyword)'", found: describe(current.kind), position: current.position
            )
        }
        _ = advance()
    }

    mutating func expectSymbol(_ symbol: String) throws {
        guard current.kind == .symbol(symbol) else {
            throw AMPLParseError.unexpectedToken(
                expected: "'\(symbol)'", found: describe(current.kind), position: current.position
            )
        }
        _ = advance()
    }

    mutating func matchSymbol(_ symbol: String) -> Bool {
        guard current.kind == .symbol(symbol) else { return false }
        _ = advance()
        return true
    }

    mutating func expectIdentifier() throws -> String {
        guard case .identifier(let name) = current.kind else {
            throw AMPLParseError.unexpectedToken(
                expected: "identifier", found: describe(current.kind), position: current.position
            )
        }
        _ = advance()
        return name
    }

    mutating func expectNumber() throws -> Double {
        guard case .number(let value) = current.kind else {
            throw AMPLParseError.unexpectedToken(
                expected: "number", found: describe(current.kind), position: current.position
            )
        }
        _ = advance()
        return value
    }

    // MARK: - model = { statement }

    mutating func parseModel() throws -> Model {
        while true {
            switch current.kind {
            case .keyword("var"):
                try parseVarDecl()
            case .keyword("param"):
                try parseParamDecl()
            case .keyword("subject"):
                try parseConstraintDecl()
            case .keyword("minimize"), .keyword("maximize"):
                try parseObjectiveDecl()
            case .endOfInput:
                return model
            default:
                throw AMPLParseError.unexpectedToken(
                    expected: "'var', 'param', 'subject to', 'minimize', or 'maximize'",
                    found: describe(current.kind), position: current.position
                )
            }
        }
    }

    // MARK: - var_decl = "var", identifier, [ bound_clause ], ";"

    mutating func parseVarDecl() throws {
        try expectKeyword("var")
        let name = try expectIdentifier()

        var lower: Double? = 0
        var upper: Double?
        var isInteger = false

        // bound_clause and "integer" may appear in either order (and
        // "integer" may appear without any bound_clause at all) — this
        // is a deliberate extension beyond the literal EBNF (which only
        // documents bound_clause), for the same reason `linear_expr`'s
        // leading-sign extension exists: real models need to write
        // `var x integer;` and `var x >= 0 integer;` both, and forcing
        // one fixed order would be an arbitrary restriction with no
        // grammatical reason behind it.
        while true {
            if case .symbol(">=") = current.kind {
                (lower, upper) = try parseBoundClause()
            } else if case .symbol("<=") = current.kind {
                (lower, upper) = try parseBoundClause()
            } else if current.kind == .keyword("integer") {
                _ = advance()
                isInteger = true
            } else {
                break
            }
        }

        try expectSymbol(";")
        model.addVariable(name, lowerBound: lower, upperBound: upper, isInteger: isInteger)
    }

    // MARK: - bound_clause

    mutating func parseBoundClause() throws -> (lower: Double?, upper: Double?) {
        var lower: Double?
        var upper: Double?
        try parseSingleBound(lower: &lower, upper: &upper)
        if matchSymbol(",") {
            try parseSingleBound(lower: &lower, upper: &upper)
        }
        return (lower, upper)
    }

    mutating func parseSingleBound(lower: inout Double?, upper: inout Double?) throws {
        if matchSymbol(">=") {
            lower = try expectNumber()
        } else if matchSymbol("<=") {
            upper = try expectNumber()
        } else {
            throw AMPLParseError.unexpectedToken(
                expected: "'>=' or '<='", found: describe(current.kind), position: current.position
            )
        }
    }

    // MARK: - param_decl = "param", identifier, ":=", number, ";"

    mutating func parseParamDecl() throws {
        try expectKeyword("param")
        let name = try expectIdentifier()
        try expectSymbol(":=")
        let value = try expectNumber()
        try expectSymbol(";")
        model.addParameter(name, value: value)
    }

    // MARK: - constraint_decl

    mutating func parseConstraintDecl() throws {
        try expectKeyword("subject")
        try expectKeyword("to")
        let name = try expectIdentifier()
        try expectSymbol(":")
        let lhs = try parseAlgebraicExpression()
        let relation = try parseRelop()
        let rhs = try parseAlgebraicExpression()
        try expectSymbol(";")
        model.addNonlinearConstraint(name: name, lhs: lhs, relation: relation, rhs: rhs)
    }

    // MARK: - objective_decl

    mutating func parseObjectiveDecl() throws {
        let sense: ObjectiveSense
        if case .keyword("minimize") = current.kind {
            sense = .minimize
            _ = advance()
        } else {
            try expectKeyword("maximize")
            sense = .maximize
        }
        let name = try expectIdentifier()
        try expectSymbol(":")
        let expression = try parseAlgebraicExpression()
        try expectSymbol(";")
        model.setNonlinearObjective(name: name, sense: sense, expression: expression)
    }

    // MARK: - relop

    mutating func parseRelop() throws -> RelationalOperator {
        if matchSymbol("<=") { return .lessThanOrEqual }
        if matchSymbol(">=") { return .greaterThanOrEqual }
        if matchSymbol("=") { return .equal }
        throw AMPLParseError.unexpectedToken(
            expected: "'<=', '>=', or '='", found: describe(current.kind), position: current.position
        )
    }

    // MARK: - algebraic expressions

    mutating func parseAlgebraicExpression() throws -> AlgebraicExpression {
        try parseSum()
    }

    mutating func parseSum() throws -> AlgebraicExpression {
        var value = try parseProduct()
        while true {
            if matchSymbol("+") { value = .add(value, try parseProduct()) }
            else if matchSymbol("-") { value = .subtract(value, try parseProduct()) }
            else { return value }
        }
    }

    mutating func parseProduct() throws -> AlgebraicExpression {
        var value = try parseUnary()
        while true {
            if matchSymbol("*") { value = .multiply(value, try parseUnary()) }
            else if matchSymbol("/") { value = .divide(value, try parseUnary()) }
            else if beginsPrimary(current.kind) {
                // AMPL permits coefficient notation such as `3 x`.
                value = .multiply(value, try parseUnary())
            } else { return value }
        }
    }

    mutating func parseUnary() throws -> AlgebraicExpression {
        if matchSymbol("+") { return try parseUnary() }
        if matchSymbol("-") { return .negate(try parseUnary()) }
        return try parsePower()
    }

    mutating func parsePower() throws -> AlgebraicExpression {
        var value = try parsePrimary()
        if matchSymbol("^") {
            let exponent = try parseUnary()
            guard case .constant(let scalar) = exponent else {
                throw AMPLParseError.unexpectedToken(
                    expected: "constant exponent", found: describe(current.kind),
                    position: current.position)
            }
            value = .power(value, scalar)
        }
        return value
    }

    mutating func parsePrimary() throws -> AlgebraicExpression {
        if case .number(let value) = current.kind {
            _ = advance(); return .constant(value)
        }
        if matchSymbol("(") {
            let value = try parseAlgebraicExpression(); try expectSymbol(")"); return value
        }
        if case .identifier(let name) = current.kind {
            _ = advance()
            if ["exp", "log", "sqrt", "sin", "cos"].contains(name), matchSymbol("(") {
                let argument = try parseAlgebraicExpression(); try expectSymbol(")")
                switch name {
                case "exp": return .exp(argument)
                case "log": return .log(argument)
                case "sqrt": return .sqrt(argument)
                case "sin": return .sin(argument)
                default: return .cos(argument)
                }
            }
            return try resolveAlgebraic(name)
        }
        throw AMPLParseError.unexpectedToken(
            expected: "number, identifier, or parenthesized expression",
            found: describe(current.kind), position: current.position)
    }

    func beginsPrimary(_ kind: TokenKind) -> Bool {
        if case .number = kind { return true }
        if case .identifier = kind { return true }
        return kind == .symbol("(")
    }

    func resolveAlgebraic(_ name: String) throws -> AlgebraicExpression {
        if let index = model.variableIndex(named: name) { return .variable(index) }
        if let value = model.parameterValues[name] { return .constant(value) }
        throw AMPLParseError.unknownIdentifier(name, position: tokens[index - 1].position)
    }

}
