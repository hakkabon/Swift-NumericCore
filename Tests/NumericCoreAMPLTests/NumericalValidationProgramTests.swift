import XCTest
@testable import NumericCoreAMPL

final class NumericalValidationProgramTests: XCTestCase {
    func testProductionReferenceProgramPasses() throws {
        let report = try NumericCoreValidationProgram.run()
        XCTAssertTrue(report.passed, "\(report)")
        XCTAssertEqual(report.cases.count, 4)
        XCTAssertEqual(report.failureCount, 0)
    }
}
