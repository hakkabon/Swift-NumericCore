import XCTest
@testable import NumericCoreAMPL

final class AMPLParserTests: XCTestCase {
    /// The exact example from `docs/design/ampl-grammar.md`.
    static let exampleSource = """
    var x >= 0;
    var y >= 0, <= 10;

    maximize profit: 3 x + 2 y;

    subject to capacity: x + y <= 4;
    subject to demand: x <= 3;
    """

    func testParsesVariableDeclarationsWithBounds() throws {
        let model = try AMPLParser.parse(Self.exampleSource)

        XCTAssertEqual(model.variableNames, ["x", "y"])
        XCTAssertEqual(model.variableBounds[0].lower, 0)
        XCTAssertNil(model.variableBounds[0].upper)
        XCTAssertEqual(model.variableBounds[1].lower, 0)
        XCTAssertEqual(model.variableBounds[1].upper, 10)
    }

    func testParsesObjective() throws {
        let model = try AMPLParser.parse(Self.exampleSource)
        let objective = try XCTUnwrap(model.objective)

        XCTAssertEqual(objective.name, "profit")
        XCTAssertEqual(objective.sense, .maximize)
        XCTAssertEqual(objective.expression.coefficients[0], 3) // x
        XCTAssertEqual(objective.expression.coefficients[1], 2) // y
        XCTAssertEqual(objective.expression.constant, 0)
    }

    func testParsesConstraints() throws {
        let model = try AMPLParser.parse(Self.exampleSource)
        XCTAssertEqual(model.constraints.count, 2)

        let capacity = model.constraints[0]
        XCTAssertEqual(capacity.name, "capacity")
        XCTAssertEqual(capacity.lhs.coefficients[0], 1) // x
        XCTAssertEqual(capacity.lhs.coefficients[1], 1) // y
        XCTAssertEqual(capacity.relation, .lessThanOrEqual)
        XCTAssertEqual(capacity.rhs.constant, 4)

        let demand = model.constraints[1]
        XCTAssertEqual(demand.name, "demand")
        XCTAssertEqual(demand.lhs.coefficients[0], 1) // x
        XCTAssertEqual(demand.relation, .lessThanOrEqual)
        XCTAssertEqual(demand.rhs.constant, 3)
    }

    func testParsesParameterAndFoldsIntoExpression() throws {
        // The grammar's `term = [number] identifier | number` only
        // allows a *number* immediately before an identifier as a
        // coefficient (`2.5 x`) — not another identifier. So a param
        // can't be written directly adjacent to a variable ("rate x")
        // as a coefficient; it has to appear as its own term, joined by
        // "+"/"-" like any other term. `rate + x` below is the valid
        // way to exercise param folding (rate -> constant 2.5) and
        // variable resolution (x -> coefficient 1) together.
        let source = """
        param rate := 2.5;
        var x >= 0;
        minimize cost: rate + x;
        """
        let model = try AMPLParser.parse(source)
        let objective = try XCTUnwrap(model.objective)

        XCTAssertEqual(objective.expression.constant, 2.5)
        XCTAssertEqual(objective.expression.coefficients[0], 1)
    }

    func testParsesLeadingNegativeCoefficient() throws {
        // The documented extension beyond the literal EBNF — see
        // AMPLParser's doc comment.
        let source = """
        var x >= 0;
        minimize cost: -3 x;
        """
        let model = try AMPLParser.parse(source)
        let objective = try XCTUnwrap(model.objective)
        XCTAssertEqual(objective.expression.coefficients[0], -3)
    }

    func testUnknownIdentifierThrows() {
        let source = """
        var x >= 0;
        minimize cost: y;
        """
        XCTAssertThrowsError(try AMPLParser.parse(source)) { error in
            guard case AMPLParseError.unknownIdentifier("y", _) = error else {
                return XCTFail("expected unknownIdentifier, got \(error)")
            }
        }
    }

    func testMissingSemicolonThrows() {
        XCTAssertThrowsError(try AMPLParser.parse("var x >= 0"))
    }

    func testEqualityConstraint() throws {
        let source = """
        var x >= 0;
        subject to fixed: x = 5;
        minimize cost: x;
        """
        let model = try AMPLParser.parse(source)
        XCTAssertEqual(model.constraints[0].relation, .equal)
    }
}
