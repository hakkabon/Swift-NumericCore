import XCTest
import NumericCore
@testable import NumericCoreAMPL

final class PresolveTests: XCTestCase {
    /// The full pipeline, end to end: parse the grammar doc's example
    /// model, compile it, and check the result against the shape
    /// documented in `docs/design/ampl-grammar.md`'s worked example.
    func testCompilesExampleModelToDocumentedShape() throws {
        let source = """
        var x >= 0;
        var y >= 0, <= 10;

        maximize profit: 3 x + 2 y;

        subject to capacity: x + y <= 4;
        subject to demand: x <= 3;
        """
        let model = try AMPLParser.parse(source)
        let problem = try model.compile()

        // maximize [3, 2] -> stored negated, minimize form.
        XCTAssertEqual(problem.objective[0], -3)
        XCTAssertEqual(problem.objective[1], -2)
        XCTAssertEqual(problem.objectiveSign, -1)

        // capacity: x + y <= 4 -> row 0: [1, 1], upper 4
        // demand:   x      <= 3 -> row 1: [1, 0], upper 3
        // A * [1, 1] = [1+1, 1+0] = [2, 1] uniquely pins down both
        // rows' coefficients at once (unlike A * e_j, which would
        // extract a column, not a row, once there's more than one row).
        let product = try problem.constraints.multiplying(Vector([1, 1]))
        XCTAssertEqual(product, Vector([2, 1]))

        XCTAssertEqual(problem.rowBounds[0].upper, 4)
        XCTAssertNil(problem.rowBounds[0].lower)
        XCTAssertEqual(problem.rowBounds[1].upper, 3)
        XCTAssertNil(problem.rowBounds[1].lower)

        XCTAssertEqual(problem.variableLowerBounds, [0, 0])
        XCTAssertEqual(problem.variableUpperBounds, [nil, 10])
    }

    func testMinimizeObjectiveIsNotNegated() throws {
        let source = """
        var x >= 0;
        minimize cost: 5 x;
        subject to lower: x >= 1;
        """
        let model = try AMPLParser.parse(source)
        let problem = try model.compile()

        XCTAssertEqual(problem.objective[0], 5)
        XCTAssertEqual(problem.objectiveSign, 1)
        XCTAssertEqual(problem.rowBounds[0].lower, 1)
        XCTAssertNil(problem.rowBounds[0].upper)
    }

    func testEqualityConstraintProducesEqualBounds() throws {
        let source = """
        var x >= 0;
        subject to fixed: x = 5;
        minimize cost: x;
        """
        let model = try AMPLParser.parse(source)
        let problem = try model.compile()

        XCTAssertEqual(problem.rowBounds[0].lower, 5)
        XCTAssertEqual(problem.rowBounds[0].upper, 5)
    }

    func testCompileThrowsWithoutObjective() throws {
        var model = Model()
        model.addVariable("x")
        XCTAssertThrowsError(try model.compile()) { error in
            XCTAssertEqual(error as? PresolveError, .noObjective)
        }
    }

    func testCompileWithNoConstraintsProducesEmptyMatrix() throws {
        let source = """
        var x >= 0;
        minimize cost: x;
        """
        let model = try AMPLParser.parse(source)
        let problem = try model.compile()
        XCTAssertEqual(problem.constraints.rows, 0)
        XCTAssertEqual(problem.constraints.nonZeroCount, 0)
    }

    func testConstraintWithVariablesOnBothSidesCombinesCorrectly() throws {
        // x - y <= 0, written as "x <= y" (variable on the rhs).
        let source = """
        var x >= 0;
        var y >= 0;
        subject to ordering: x <= y;
        minimize cost: x;
        """
        let model = try AMPLParser.parse(source)
        let problem = try model.compile()

        let row = try problem.constraints.multiplying(Vector([1, 0]))
        XCTAssertEqual(row[0], 1)   // coefficient of x
        let rowY = try problem.constraints.multiplying(Vector([0, 1]))
        XCTAssertEqual(rowY[0], -1) // coefficient of y is -1 (moved to lhs)
        XCTAssertEqual(problem.rowBounds[0].upper, 0)
    }
}
