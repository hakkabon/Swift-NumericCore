import XCTest
@testable import NumericCoreAMPL

/// The full loop: AMPL source text -> parse -> compile -> solve.
/// Uses the exact example from `docs/design/ampl-grammar.md`, whose
/// optimum was independently hand-verified by geometry in that doc and
/// cross-checked on the Rust side by both `nc-optimize` solvers
/// agreeing with each other on the same problem.
final class SolveTests: XCTestCase {
    static let exampleSource = """
    var x >= 0;
    var y >= 0, <= 10;

    maximize profit: 3 x + 2 y;

    subject to capacity: x + y <= 4;
    subject to demand: x <= 3;
    """

    func testSolvesTheGrammarDocExampleViaSimplex() throws {
        let model = try AMPLParser.parse(Self.exampleSource)
        let problem = try model.compile()
        let solution = try problem.solve(using: .simplex)

        XCTAssertEqual(solution.status, .optimal)
        // objectiveValue is already corrected back to the model's
        // maximize sense (not the internal negated minimize-form value).
        XCTAssertEqual(solution.objectiveValue, 11.0, accuracy: 1e-6)
        XCTAssertEqual(solution.variableValues[0], 3.0, accuracy: 1e-6) // x
        XCTAssertEqual(solution.variableValues[1], 1.0, accuracy: 1e-6) // y
    }

    func testSolvesTheGrammarDocExampleViaInteriorPoint() throws {
        let model = try AMPLParser.parse(Self.exampleSource)
        let problem = try model.compile()
        let solution = try problem.solve(using: .interiorPoint)

        XCTAssertEqual(solution.status, .optimal)
        XCTAssertEqual(solution.objectiveValue, 11.0, accuracy: 1e-3)
        XCTAssertEqual(solution.variableValues[0], 3.0, accuracy: 1e-3)
        XCTAssertEqual(solution.variableValues[1], 1.0, accuracy: 1e-3)
    }

    func testDefaultSolverIsSimplex() throws {
        let model = try AMPLParser.parse(Self.exampleSource)
        let problem = try model.compile()
        let solution = try problem.solve() // no `using:` argument
        XCTAssertEqual(solution.status, .optimal)
        XCTAssertEqual(solution.objectiveValue, 11.0, accuracy: 1e-6)
    }

    func testMinimizeObjectiveNeedsNoSignCorrection() throws {
        let source = """
        var x >= 0;
        minimize cost: 5 x;
        subject to lower: x >= 1;
        """
        let model = try AMPLParser.parse(source)
        let problem = try model.compile()
        let solution = try problem.solve(using: .simplex)

        XCTAssertEqual(solution.status, .optimal)
        XCTAssertEqual(solution.objectiveValue, 5.0, accuracy: 1e-6)
        XCTAssertEqual(solution.variableValues[0], 1.0, accuracy: 1e-6)
    }

    func testInfeasibleModelIsDetected() throws {
        let source = """
        var x >= 0;
        subject to upper: x <= 1;
        subject to lower: x >= 2;
        minimize cost: x;
        """
        let model = try AMPLParser.parse(source)
        let problem = try model.compile()
        let solution = try problem.solve(using: .simplex)
        XCTAssertEqual(solution.status, .infeasible)
    }

    func testInteriorPointRejectsEqualityConstraint() throws {
        let source = """
        var x >= 0, <= 10;
        subject to fixed: x = 5;
        minimize cost: x;
        """
        let model = try AMPLParser.parse(source)
        let problem = try model.compile()
        // RevisedSimplexSolver handles this fine...
        let simplexSolution = try problem.solve(using: .simplex)
        XCTAssertEqual(simplexSolution.status, .optimal)
        // ...but InteriorPointSolver documents that it rejects
        // equality-constrained rows outright.
        XCTAssertThrowsError(try problem.solve(using: .interiorPoint))
    }
}
