import XCTest
@testable import NumericCoreAMPL

final class NumericalValidationProgramTests: XCTestCase {
    func testProductionReferenceProgramPasses() throws {
        let report = try NumericCoreValidationProgram.run()
        XCTAssertTrue(report.passed, "\(report)")
        XCTAssertEqual(report.cases.count, 9)
        XCTAssertEqual(report.failureCount, 0)
        XCTAssertLessThanOrEqual(report.maximumNormalizedError, 1)
        XCTAssertEqual(report.cases.compactMap(\.provenance).count, 2)
    }
}
