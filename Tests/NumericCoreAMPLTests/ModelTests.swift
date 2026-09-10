import XCTest
@testable import NumericCoreAMPL

final class ModelTests: XCTestCase {
    func testAddVariableReturnsSequentialIndices() {
        var model = Model()
        let x = model.addVariable("x")
        let y = model.addVariable("y", lowerBound: nil, upperBound: 10)

        XCTAssertEqual(x, 0)
        XCTAssertEqual(y, 1)
        XCTAssertEqual(model.variableNames, ["x", "y"])
        XCTAssertEqual(model.variableBounds[0].lower, 0) // default lower bound
        XCTAssertNil(model.variableBounds[1].lower)
        XCTAssertEqual(model.variableBounds[1].upper, 10)
    }
}
