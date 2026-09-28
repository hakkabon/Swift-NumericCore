import XCTest
import NumericCore
import NumericCoreAccelerate

final class NumericalDiagnosticsTests: XCTestCase {
    func testScaleAwareQRRankDecisionIsInvariantUnderUniformScaling() throws {
        let original = try Matrix<Double>(rows: [[1e12, 0], [0, 1e-8]])
        let scaled = try Matrix<Double>(rows: [[1, 0], [0, 1e-20]])
        let rhs = Vector<Double>([1, 1])

        let first = try AccelerateBackend.leastSquaresReport(
            design: original, response: rhs
        )
        let second = try AccelerateBackend.leastSquaresReport(
            design: scaled, response: rhs
        )

        XCTAssertEqual(first.termination, .rankDeficient)
        XCTAssertEqual(second.termination, .rankDeficient)
        XCTAssertEqual(first.estimatedRank, second.estimatedRank)
        XCTAssertNil(first.solution)
        XCTAssertNil(second.solution)
    }

    func testQRReportContainsResidualRankAndThreshold() throws {
        let matrix = try Matrix<Double>(rows: [[3, 1], [1, 2]])
        let response = Vector<Double>([9, 8])

        let report = try AccelerateBackend.solveReport(matrix, response)

        XCTAssertEqual(report.termination, .converged)
        XCTAssertEqual(report.estimatedRank, 2)
        XCTAssertNotNil(report.decisionThreshold)
        XCTAssertLessThan(try XCTUnwrap(report.relativeResidual), 1e-14)
        let solution = try XCTUnwrap(report.solution)
        XCTAssertEqual(solution[0], 2, accuracy: 1e-14)
        XCTAssertEqual(solution[1], 3, accuracy: 1e-14)
    }

    func testDirectSolverReportsDistinguishNumericalFailureKinds() throws {
        let singular = try Matrix<Double>(rows: [[1, 2], [2, 4]])
        let indefinite = try Matrix<Double>(rows: [[1, 2], [2, 1]])
        let response = Vector<Double>([1, 2])

        XCTAssertEqual(
            try AccelerateBackend.solveLUReport(singular, response).termination,
            .singular
        )
        XCTAssertEqual(
            try AccelerateBackend.solveSPDReport(indefinite, response).termination,
            .notPositiveDefinite
        )
    }

    func testToleranceCombinesAbsoluteRelativeScaleAndDimension() {
        let tolerance = NumericalTolerance(absolute: 1e-8, relative: 1e-6)
        XCTAssertEqual(tolerance.threshold(scale: 10, dimension: 4), 4e-5, accuracy: 1e-20)
        XCTAssertEqual(tolerance.threshold(scale: 0, dimension: 4), 1e-8)
    }

    func testInvalidToleranceIsReportedRatherThanTrapping() throws {
        let matrix = try Matrix<Double>(rows: [[1.0]])
        let response = Vector<Double>([1.0])
        XCTAssertThrowsError(try AccelerateBackend.solveReport(
            matrix, response,
            tolerance: NumericalTolerance(absolute: -.infinity, relative: .nan)
        )) { error in
            guard case LinearAlgebraError.invalidTolerance = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRandomizedDiagonallyDominantSystemsHaveVerifiedResiduals() throws {
        var state: UInt64 = 0x4E554D45524943
        func sample() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Double(state >> 11) / Double(UInt64.max >> 11) - 0.5
        }

        for _ in 0..<32 {
            let size = 5
            var rows = [[Double]](
                repeating: [Double](repeating: 0, count: size), count: size
            )
            for row in 0..<size {
                var offDiagonalMagnitude = 0.0
                for column in 0..<size where column != row {
                    rows[row][column] = sample()
                    offDiagonalMagnitude += abs(rows[row][column])
                }
                rows[row][row] = offDiagonalMagnitude + 1 + abs(sample())
            }
            let matrix = try Matrix<Double>(rows: rows)
            let expected = Vector<Double>((0..<size).map { _ in sample() })
            let response = Vector<Double>((0..<size).map { row in
                (0..<size).reduce(0) { $0 + matrix[row, $1] * expected[$1] }
            })

            let report = try AccelerateBackend.solveReport(matrix, response)
            XCTAssertEqual(report.termination, .converged)
            XCTAssertLessThan(try XCTUnwrap(report.relativeResidual), 1e-14)
        }
    }
}
