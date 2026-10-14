import XCTest
@testable import NumericCoreOptimization

final class ConstrainedDerivativeFreeTests:XCTestCase{
    func testEqualityConstrainedValueOnlyProblem()throws{
        let result=try ConstrainedDerivativeFree.minimize(initial:[-1,2],constraintKinds:[.equality]){x in
            .init(objective:x[0]*x[0]+x[1]*x[1],constraints:[x[0]+x[1]-1])}
        XCTAssertEqual(result.termination,.converged)
        XCTAssertEqual(result.point[0],0.5,accuracy:2e-3);XCTAssertEqual(result.point[1],0.5,accuracy:2e-3)
        XCTAssertLessThan(result.maximumViolation,1e-6)
    }
    func testActiveInequalityFromInfeasibleStart()throws{
        let result=try ConstrainedDerivativeFree.minimize(initial:[0],constraintKinds:[.lessEqual]){x in
            .init(objective:x[0]*x[0],constraints:[1-x[0]])}
        XCTAssertEqual(result.point[0],1,accuracy:2e-3);XCTAssertLessThan(result.maximumViolation,1e-6)
        XCTAssertGreaterThan(result.feasibilityImprovingSteps,0)
    }
    func testCancellationAndInvalidEvaluationAreExplicit()throws{
        let cancelled=try ConstrainedDerivativeFree.minimize(initial:[0],constraintKinds:[.lessEqual],observer:{_ in false}){_ in .init(objective:0,constraints:[-1])}
        XCTAssertEqual(cancelled.termination,.cancelled)
        XCTAssertThrowsError(try ConstrainedDerivativeFree.minimize(initial:[0],constraintKinds:[.lessEqual]){_ in .init(objective:0,constraints:[])})
    }
}
