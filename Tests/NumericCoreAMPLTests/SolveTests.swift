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
        XCTAssertTrue(solution.diagnostics.isVerified(tolerance: 1e-8))
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

    func testAutomaticSolverUsesSimplexForContinuousModel() throws {
        let model = try AMPLParser.parse(Self.exampleSource)
        let problem = try model.compile()
        let solution = try problem.solve() // no `using:` argument
        XCTAssertEqual(solution.status, .optimal)
        XCTAssertEqual(solution.objectiveValue, 11.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(solution.variableValuesByName["x"]), 3.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(solution.variableValuesByName["y"]), 1.0, accuracy: 1e-6)
        XCTAssertTrue(solution.isVerified(tolerance: 1e-8))
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

    func testObjectiveConstantIsPreservedInPublicResultAndDiagnostics() throws {
        let source = """
        var x >= 0;
        maximize value: 3 x + 7;
        subject to cap: x <= 2;
        """
        let solution = try AMPLParser.parse(source).compile().solve()
        XCTAssertEqual(solution.status, .optimal)
        XCTAssertEqual(solution.objectiveValue, 13, accuracy: 1e-9)
        XCTAssertEqual(solution.diagnostics.recomputedObjectiveValue, 13, accuracy: 1e-9)
        XCTAssertTrue(solution.isVerified(tolerance: 1e-8))
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
        XCTAssertFalse(solution.isVerified(tolerance: 1e-8))
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

    func testBranchAndBoundSolvesAnIntegerModel() throws {
        // Same classic MILP as nc-optimize's own branch_and_bound tests,
        // now expressed as AMPL source and run through the full
        // parse -> compile -> solve loop: maximize 5x+4y s.t.
        // 6x+4y<=24, x+2y<=6, x,y>=0 integer. LP relaxation lands on a
        // genuinely fractional vertex (3, 1.5); hand-verified integer
        // optimum is (4, 0), objective 20.
        let source = """
        var x >= 0 integer;
        var y >= 0 integer;

        maximize profit: 5 x + 4 y;

        subject to c1: 6 x + 4 y <= 24;
        subject to c2: x + 2 y <= 6;
        """
        let model = try AMPLParser.parse(source)
        let problem = try model.compile()
        let solution = try problem.solve(using: .branchAndBound)

        XCTAssertEqual(solution.status, .optimal)
        XCTAssertEqual(solution.variableValues[0], 4.0, accuracy: 1e-6) // x
        XCTAssertEqual(solution.variableValues[1], 0.0, accuracy: 1e-6) // y
        XCTAssertEqual(solution.objectiveValue, 20.0, accuracy: 1e-6)
        XCTAssertTrue(solution.diagnostics.isVerified(tolerance: 1e-8))
    }

    func testAutomaticSolverHonorsIntegrality() throws {
        let source = """
        var x >= 0 integer;
        var y >= 0 integer;
        maximize profit: 5 x + 4 y;
        subject to c1: 6 x + 4 y <= 24;
        subject to c2: x + 2 y <= 6;
        """
        let solution = try AMPLParser.parse(source).compile().solve()

        XCTAssertEqual(solution.status, .optimal)
        XCTAssertEqual(try XCTUnwrap(solution.variableValuesByName["x"]), 4.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(solution.variableValuesByName["y"]), 0.0, accuracy: 1e-6)
        XCTAssertEqual(solution.objectiveValue, 20.0, accuracy: 1e-6)
        XCTAssertTrue(solution.isVerified(tolerance: 1e-8))
    }

    func testSimplexIgnoresIntegralityUnlikeBranchAndBoundOnTheSameModel() throws {
        // The same model as above, but solved via .simplex - which
        // ignores the "integer" qualifier entirely and returns the
        // fractional LP relaxation optimum instead. Demonstrates why
        // solver choice matters once a model declares an integer
        // variable, rather than asserting it as an implicit assumption.
        let source = """
        var x >= 0 integer;
        var y >= 0 integer;

        maximize profit: 5 x + 4 y;

        subject to c1: 6 x + 4 y <= 24;
        subject to c2: x + 2 y <= 6;
        """
        let model = try AMPLParser.parse(source)
        let problem = try model.compile()
        let solution = try problem.solve(using: .simplex)

        XCTAssertEqual(solution.status, .optimal)
        XCTAssertEqual(solution.variableValues[0], 3.0, accuracy: 1e-6)
        XCTAssertEqual(solution.variableValues[1], 1.5, accuracy: 1e-6)
        XCTAssertEqual(solution.objectiveValue, 21.0, accuracy: 1e-6)
        XCTAssertEqual(solution.diagnostics.maximumIntegralityViolation, 0.5, accuracy: 1e-9)
        XCTAssertFalse(solution.diagnostics.isVerified(tolerance: 1e-8))
    }

    func testBranchAndBoundDetectsIntegralityInfeasibility() throws {
        // x integer, 2x = 1 - the LP relaxation (x = 0.5) is feasible,
        // but no integer x can ever satisfy the equality.
        let source = """
        var x >= 0, <= 10 integer;
        subject to fixed: 2 x = 1;
        minimize cost: x;
        """
        let model = try AMPLParser.parse(source)
        let problem = try model.compile()
        let solution = try problem.solve(using: .branchAndBound)
        XCTAssertEqual(solution.status, .infeasible)
    }

    func testConfiguredBranchAndBoundReturnsSearchCertificate() throws {
        let source = """
        var x >= 0 integer;
        var y >= 0 integer;
        maximize profit: 5 x + 4 y;
        subject to c1: 6 x + 4 y <= 24;
        subject to c2: x + 2 y <= 6;
        """
        let solution = try AMPLParser.parse(source).compile().solve(
            configuration: .branchAndBound(.init(maxNodes: 3, integerTolerance: 1e-6))
        )

        XCTAssertEqual(solution.status, .iterationLimit)
        let report = try XCTUnwrap(solution.searchReport)
        XCTAssertEqual(report.nodesExplored, 3)
        XCTAssertNotNil(report.bestBound)
        XCTAssertNotNil(report.absoluteGap)
        XCTAssertNotNil(report.relativeGap)
        XCTAssertTrue(solution.diagnostics.isVerified(tolerance: 1e-8))
    }

    func testNodeLimitBeforeIncumbentHasNoGapCertificate() throws {
        let source = """
        var x >= 0 integer;
        var y >= 0 integer;
        maximize profit: 5 x + 4 y;
        subject to c1: 6 x + 4 y <= 24;
        subject to c2: x + 2 y <= 6;
        """
        let solution = try AMPLParser.parse(source).compile().solve(
            configuration: .branchAndBound(.init(maxNodes: 2, integerTolerance: 1e-6))
        )

        XCTAssertEqual(solution.status, .iterationLimit)
        let report = try XCTUnwrap(solution.searchReport)
        XCTAssertEqual(report.nodesExplored, 2)
        XCTAssertNotNil(report.bestBound)
        XCTAssertNil(report.absoluteGap)
        XCTAssertNil(report.relativeGap)
        XCTAssertFalse(solution.diagnostics.finite)
    }

    func testBranchAndBoundWarmStartSurvivesEarlyNodeLimit() throws {
        let source = """
        var x >= 0 integer;
        var y >= 0 integer;
        maximize profit: 5 x + 4 y;
        subject to c1: 6 x + 4 y <= 24;
        subject to c2: x + 2 y <= 6;
        """
        let solution = try AMPLParser.parse(source).compile().solve(
            configuration: .branchAndBound(.init(
                maxNodes: 1, scaling: true, initialIncumbent: [4, 0]
            ))
        )
        XCTAssertEqual(solution.status, .iterationLimit)
        XCTAssertEqual(solution.variableValues, [4, 0])
        XCTAssertEqual(solution.objectiveValue, 20, accuracy: 1e-12)
        XCTAssertTrue(solution.diagnostics.isVerified(tolerance: 1e-8))
    }

    func testConfiguredSimplexPreservesExistingSolutionPath() throws {
        let solution = try AMPLParser.parse(Self.exampleSource).compile().solve(
            configuration: .simplex(.init(maxIterations: 1_000, tolerance: 1e-10))
        )
        XCTAssertEqual(solution.status, .optimal)
        XCTAssertEqual(solution.objectiveValue, 11.0, accuracy: 1e-8)
        XCTAssertNil(solution.searchReport)
    }
}
