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
/// One deliberate, documented extension beyond the literal EBNF: a
/// `linear_expr` may start with a leading `+`/`-` (e.g. `-3 x + 2 y`),
/// which the published grammar doesn't cover (`linear_expr = term, {
/// ("+"|"-"), term }` has no leading-sign case for the *first* term).
/// Rejecting a leading negative coefficient would make this parser
/// unable to express a genuinely ordinary LP, so this parses the
/// optional leading sign before the first term rather than requiring
/// the awkward `0 - 3 x + 2 y` workaround.
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
        if case .symbol(">=") = current.kind {
            (lower, upper) = try parseBoundClause()
        } else if case .symbol("<=") = current.kind {
            (lower, upper) = try parseBoundClause()
        }

        try expectSymbol(";")
        model.addVariable(name, lowerBound: lower, upperBound: upper)
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
        let lhs = try parseLinearExpr()
        let relation = try parseRelop()
        let rhs = try parseLinearExpr()
        try expectSymbol(";")
        model.addConstraint(name: name, lhs: lhs, relation: relation, rhs: rhs)
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
        let expression = try parseLinearExpr()
        try expectSymbol(";")
        model.setObjective(name: name, sense: sense, expression: expression)
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

    // MARK: - linear_expr = term, { ("+"|"-"), term }
    // (plus the leading-sign extension documented on AMPLParser)

    mutating func parseLinearExpr() throws -> LinearExpression {
        var expr = LinearExpression()

        var leadingSign = 1.0
        if matchSymbol("+") {
            leadingSign = 1
        } else if matchSymbol("-") {
            leadingSign = -1
        }
        try parseTerm(into: &expr, sign: leadingSign)

        while true {
            if matchSymbol("+") {
                try parseTerm(into: &expr, sign: 1)
            } else if matchSymbol("-") {
                try parseTerm(into: &expr, sign: -1)
            } else {
                break
            }
        }
        return expr
    }

    // MARK: - term = [ number ], identifier | number

    mutating func parseTerm(into expr: inout LinearExpression, sign: Double) throws {
        if case .number(let n) = current.kind {
            _ = advance()
            let coefficient = sign * n
            if case .identifier(let name) = current.kind {
                _ = advance()
                try resolve(name, coefficient: coefficient, into: &expr)
            } else {
                expr.add(constant: coefficient)
            }
        } else if case .identifier(let name) = current.kind {
            _ = advance()
            try resolve(name, coefficient: sign, into: &expr)
        } else {
            throw AMPLParseError.unexpectedToken(
                expected: "number or identifier", found: describe(current.kind), position: current.position
            )
        }
    }

    /// Resolves an identifier against the model's declared variables
    /// and parameters — see `Model.swift`'s module docs on why this
    /// dual resolution exists even though the published EBNF's `term`
    /// production doesn't distinguish the two: a param reference folds
    /// into `constant`, a variable reference becomes a coefficient.
    func resolve(_ name: String, coefficient: Double, into expr: inout LinearExpression) throws {
        if let variableIndex = model.variableIndex(named: name) {
            expr.add(coefficient: coefficient, variableIndex: variableIndex)
        } else if let paramValue = model.parameterValues[name] {
            expr.add(constant: coefficient * paramValue)
        } else {
            throw AMPLParseError.unknownIdentifier(name, position: tokens[index - 1].position)
        }
    }
}
