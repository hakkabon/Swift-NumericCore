import XCTest
@testable import NumericCore

final class NumericalValidationTests: XCTestCase {
    func testScaleAwareMetricsAndReportsFailClosed() {
        let tolerance = ValidationTolerance(absolute: 1e-12, relative: 1e-6)
        let good = ValidationMetric(
            name: "large", observed: 1e9 + 100, reference: 1e9, tolerance: tolerance)
        let bad = ValidationMetric(
            name: "nonfinite", observed: .nan, reference: 0, tolerance: tolerance)
        XCTAssertTrue(good.passed)
        XCTAssertFalse(bad.passed)
        let report = ValidationReport(cases: [.init(name: "case", metrics: [good, bad])])
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.failureCount, 1)
    }

    func testLinearSystemBackwardErrorIsIndependent() {
        let exact = NumericalValidation.linearSystem(
            matrix: [[3, 1], [1, 2]], solution: [2, 3], rightHandSide: [9, 8])
        XCTAssertTrue(exact.isVerified(tolerance: 1e-15))
        let wrong = NumericalValidation.linearSystem(
            matrix: [[3, 1], [1, 2]], solution: [2, 2], rightHandSide: [9, 8])
        XCTAssertFalse(wrong.isVerified(tolerance: 1e-3))
    }

    func testDeterministicPerturbationsAreStableAndBounded() {
        let values = [0.0, 2.0, -3.0]
        let first = NumericalValidation.perturb(values, seed: 42, relativeMagnitude: 1e-4)
        XCTAssertEqual(first, NumericalValidation.perturb(
            values, seed: 42, relativeMagnitude: 1e-4))
        XCTAssertEqual(first, [
            1.3646065328781521e-5, 1.9998901853715791, -3.0000522970087022,
        ])
        for (perturbed, original) in zip(first, values) {
            XCTAssertLessThanOrEqual(abs(perturbed - original), 1e-4 * max(abs(original), 1))
        }
    }
}
