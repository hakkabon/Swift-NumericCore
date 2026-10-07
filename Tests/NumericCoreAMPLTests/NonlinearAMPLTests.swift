import Foundation
import XCTest
import NumericCoreOptimization
@testable import NumericCoreAMPL

final class NonlinearAMPLTests: XCTestCase {
    private static let constrainedSource = """
    var x >= 0;
    minimize distance: (x - 2)^2;
    subject to unit: x^2 <= 1;
    """

    func testParsesPrecedenceFunctionsAndNonlinearStructure() throws {
        let source = """
        param shift := 2;
        var x >= 0;
        minimize objective: sin(x)^2 + (exp(x) - shift)^2;
        subject to domain: sqrt(x + 1) <= 2;
        """
        let model = try AMPLParser.parse(source)
        XCTAssertNil(model.objective?.algebraicExpression?.affine)
        XCTAssertNil(model.constraints[0].algebraicLHS?.affine)
        let compiled = try model.compileNonlinear()
        let evaluation = try compiled.model.evaluateObjective(parameters: [0])
        XCTAssertEqual(evaluation.value, 1, accuracy: 1e-12)
        XCTAssertEqual(evaluation.gradient[0], -2, accuracy: 1e-12)
    }

    func testConstrainedNonlinearAMPLSolvesWithSwiftAndRustSQP() throws {
        let compiled = try AMPLParser.parse(Self.constrainedSource).compileNonlinear()
        let swift = try compiled.solve(
            initial: [0.5], configuration: .sqp(backend: .swift, options: .init()))
        let rust = try compiled.solve(
            initial: [0.5], configuration: .sqp(backend: .rust, options: .init()))
        for result in [swift, rust] {
            XCTAssertEqual(result.status, .converged)
            XCTAssertEqual(result.variableValuesByName["x"]!, 1, accuracy: 1e-5)
            XCTAssertEqual(result.objectiveValue, 1, accuracy: 1e-5)
            XCTAssertLessThan(result.maximumViolation, 1e-7)
            XCTAssertTrue(result.isVerified(
                feasibilityTolerance: 1e-6, stationarityTolerance: 1e-5))
        }
        XCTAssertEqual(rust.variableValues[0], swift.variableValues[0], accuracy: 1e-7)
    }

    func testUnconstrainedNonlinearAMPLUsesBoundedLBFGS() throws {
        let source = """
        var x >= 0, <= 2;
        minimize fit: (exp(x) - 2)^2;
        """
        let compiled = try AMPLParser.parse(source).compileNonlinear()
        let result = try compiled.solve(initial: [0.25])
        XCTAssertEqual(result.status, .converged)
        XCTAssertEqual(result.variableValuesByName["x"]!, Foundation.log(2), accuracy: 1e-5)
        XCTAssertEqual(result.objectiveValue, 0, accuracy: 1e-9)
    }

    func testMaximizeSenseIsRestoredAfterInternalMinimization() throws {
        let source = """
        var x >= 0;
        maximize reward: x;
        subject to unit: x^2 <= 1;
        """
        let result = try AMPLParser.parse(source).compileNonlinear().solve(initial: [0.5])
        XCTAssertEqual(result.status, .converged)
        XCTAssertEqual(result.variableValuesByName["x"]!, 1, accuracy: 1e-5)
        XCTAssertEqual(result.objectiveValue, 1, accuracy: 1e-5)
    }

    func testNonlinearCompilerRejectsIntegerVariables() throws {
        let source = """
        var x >= 0 integer;
        minimize objective: x^2;
        """
        XCTAssertThrowsError(try AMPLParser.parse(source).compileNonlinear()) {
            XCTAssertEqual($0 as? NonlinearPresolveError, .integerVariablesUnsupported)
        }
    }

    func testLinearCompilerRejectsNonlinearModelRatherThanDroppingTerms() throws {
        let model = try AMPLParser.parse(Self.constrainedSource)
        XCTAssertThrowsError(try model.compile()) {
            XCTAssertEqual($0 as? PresolveError, .nonlinearExpressionRequiresNonlinearCompiler)
        }
    }

    func testParserRejectsVariableExponent() throws {
        let source = """
        var x;
        var y;
        minimize objective: x^y;
        """
        XCTAssertThrowsError(try AMPLParser.parse(source))
    }
}
