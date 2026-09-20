import Foundation
import XCTest
@testable import NumericCore
@testable import NumericCoreAccelerate

private struct SolverFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let matrix: [[Double]]
        let response: [Double]
        let expected: [Double]?
        let positiveDefinite: Bool
    }

    let schemaVersion: Int
    let tolerance: Double
    let cases: [Case]
}

final class SolverConformanceTests: XCTestCase {
    func testSharedDataLensSolverContract() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "solver-conformance", withExtension: "json", subdirectory: "Fixtures"
        ))
        let fixture = try JSONDecoder().decode(SolverFixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.schemaVersion, 1)

        for item in fixture.cases {
            let actual = StatisticalSolver.solve(item.matrix, item.response)
            if let expected = item.expected {
                let solved = try XCTUnwrap(actual, "missing solution for \(item.name)")
                XCTAssertEqual(solved.count, expected.count)
                for (lhs, rhs) in zip(solved, expected) {
                    XCTAssertEqual(lhs, rhs, accuracy: fixture.tolerance, item.name)
                }
                if item.positiveDefinite {
                    let spd = try XCTUnwrap(StatisticalSolver.solveSPD(item.matrix, item.response))
                    for (lhs, rhs) in zip(spd, expected) {
                        XCTAssertEqual(lhs, rhs, accuracy: fixture.tolerance, item.name)
                    }
                }
            } else {
                XCTAssertNil(actual, "expected singular verdict for \(item.name)")
            }
        }
    }

    func testStatisticalSolverLeastSquaresAndInvalidShapes() throws {
        let leastSquares = try XCTUnwrap(StatisticalSolver.leastSquares(
            design: [[1, 0], [1, 1], [1, 2]], response: [1, 3, 5]
        ))
        XCTAssertEqual(leastSquares.count, 2)
        XCTAssertEqual(leastSquares[0], 1, accuracy: 1e-12)
        XCTAssertEqual(leastSquares[1], 2, accuracy: 1e-12)
        XCTAssertNil(StatisticalSolver.leastSquares(design: [[1, 1], [2, 2]], response: [1, 2]))
        XCTAssertNil(StatisticalSolver.leastSquares(design: [[1]], response: [1, 2]))
        XCTAssertNil(StatisticalSolver.solve([[1, 2], [2, 4]], [3, 6]))
        XCTAssertNil(StatisticalSolver.solveSPD([[1, 2], [2, 1]], [3, 3]))
    }
}
