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
            let matrix = try Matrix<Double>(rows: item.matrix)
            let response = Vector(item.response)
            let actual = try AccelerateBackend.solve(matrix, response)
            if let expected = item.expected {
                let solved = try XCTUnwrap(actual, "missing solution for \(item.name)")
                XCTAssertEqual(solved.count, expected.count)
                for (lhs, rhs) in zip(solved.storage, expected) {
                    XCTAssertEqual(lhs, rhs, accuracy: fixture.tolerance, item.name)
                }
                if item.positiveDefinite {
                    let spd = try XCTUnwrap(try AccelerateBackend.solveSPD(matrix, response))
                    for (lhs, rhs) in zip(spd.storage, expected) {
                        XCTAssertEqual(lhs, rhs, accuracy: fixture.tolerance, item.name)
                    }
                }
            } else {
                XCTAssertNil(actual, "expected singular verdict for \(item.name)")
            }
        }
    }
}
