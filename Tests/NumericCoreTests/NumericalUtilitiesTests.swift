import XCTest
@testable import NumericCore

final class NumericalUtilitiesTests: XCTestCase {
    func testLogarithmicGridIncludesExactBounds() throws {
        let grid = try NumericalGrid.logarithmic(from: 20, through: 20_000, pointsPerOctave: 12)
        XCTAssertEqual(grid.first, 20)
        XCTAssertEqual(try XCTUnwrap(grid.last), 20_000, accuracy: 1e-10)
        XCTAssertTrue(zip(grid, grid.dropFirst()).allSatisfy(<))
    }

    func testInterpolationQuantileAndWrappedPhase() throws {
        XCTAssertEqual(try NumericalInterpolation.logarithmicMagnitude(lower: 1, upper: 100, fraction: 0.5), 10, accuracy: 1e-12)
        XCTAssertEqual(try DescriptiveStatistics.quantile([30, 0, 20, 10], probability: 0.5), 15)
        XCTAssertEqual(try NumericalInterpolation.wrappedPhase(lower: 170, upper: -170, fraction: 0.5, period: 360), 180)
    }

    func testStratifiedSamplingIsDeterministicAndBounded() throws {
        var first = SplitMix64Generator(seed: 42), second = SplitMix64Generator(seed: 42)
        let a = try (0..<20).map { try StratifiedSampling.unitInterval(sample: $0, count: 20, dimension: 3, generator: &first) }
        let b = try (0..<20).map { try StratifiedSampling.unitInterval(sample: $0, count: 20, dimension: 3, generator: &second) }
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.allSatisfy { (0..<1).contains($0) })
    }

    func testRelaxedFixedPointConverges() throws {
        let result = try FixedPointSolver.solve(
            initial: 1, options: .init(maximumIterations: 100, absoluteTolerance: 1e-12, relaxation: 0.5)
        ) { 2 / $0 }
        XCTAssertEqual(result.value, sqrt(2), accuracy: 1e-10)
        XCTAssertGreaterThan(result.iterations, 0)
    }

    func testBesselJ1KnownValuesAndOddSymmetry() {
        XCTAssertEqual(SpecialFunctions.besselJ1(0), 0)
        XCTAssertEqual(SpecialFunctions.besselJ1(1), 0.4400505857449335, accuracy: 1e-12)
        XCTAssertEqual(SpecialFunctions.besselJ1(-1), -SpecialFunctions.besselJ1(1), accuracy: 1e-15)
    }
}
