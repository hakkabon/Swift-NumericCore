import XCTest
import NumericCore
@testable import NumericCoreAMPL

final class NumericalValidationProgramTests: XCTestCase {
    func testProductionReferenceProgramPasses() throws {
        let report = try NumericCoreValidationProgram.run()
        XCTAssertTrue(report.passed, "\(report)")
        XCTAssertEqual(report.cases.count, 14)
        XCTAssertEqual(report.failureCount, 0)
        XCTAssertLessThanOrEqual(report.maximumNormalizedError, 1)
        XCTAssertEqual(report.cases.compactMap(\.provenance).count, 2)
        XCTAssertEqual(report.filtered(through: .smoke).cases.count, 4)
        XCTAssertEqual(report.filtered(through: .standard).cases.count, 14)

        let first = report.snapshot(implementation: "swift", tier: .standard)
        let second = try NumericCoreValidationProgram.run()
            .snapshot(implementation: "swift", tier: .standard)
        XCTAssertEqual(try first.jsonData(), try second.jsonData())
        XCTAssertTrue(second.regressions(against: first).isEmpty)
        XCTAssertEqual(first.manifest.count, 14)
        XCTAssertEqual(Set(first.manifest.map(\.id)).count, 14)
        XCTAssertTrue(first.manifestIssues.isEmpty)
    }

    func testSnapshotDetectsNumericalRegression() throws {
        let tolerance = ValidationTolerance(absolute: 0.1, relative: 0)
        let baseline = ValidationReport(cases: [
            .init(id: "stable.case", family: "test", name: "case", metrics: [
                .init(name: "metric", observed: 1, reference: 1, tolerance: tolerance),
            ]),
        ]).snapshot(implementation: "swift", tier: .smoke)
        let current = ValidationReport(cases: [
            .init(id: "stable.case", family: "test", name: "case", metrics: [
                .init(name: "metric", observed: 2, reference: 1, tolerance: tolerance),
            ]),
        ]).snapshot(implementation: "swift", tier: .smoke)
        XCTAssertEqual(current.regressions(against: baseline).count, 1)
    }
}
