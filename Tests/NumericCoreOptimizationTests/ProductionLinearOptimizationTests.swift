import XCTest
@testable import NumericCoreOptimization

final class ProductionLinearOptimizationTests: XCTestCase {
    private func model(integer: Bool, equality: Bool = true) throws -> SparseLinearProblem {
        try .init(objective: [2, 1], rows: 1, columns: 2,
                  rowPointers: [0, 2], columnIndices: [0, 1], values: [1, 1],
                  rowBounds: [.init(lower: 3, upper: equality ? 3 : nil)],
                  variableBounds: [.init(lower: equality ? 1 : 0,
                                         upper: equality ? 1 : 3),
                                   .init(lower: 0, upper: 10)],
                  isInteger: [integer, integer])
    }

    func testPresolvesPostsolvesAndCertifiesLP() throws {
        let result = try ProductionLinearSolver.solve(model(integer: false))
        XCTAssertEqual(result.point, [1, 2])
        XCTAssertEqual(result.objective, 4, accuracy: 1e-10)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.reducedVariables, 0)
    }

    func testAutomaticMethodHonorsIntegrality() throws {
        let result = try ProductionLinearSolver.solve(model(integer: true, equality: false))
        XCTAssertTrue(result.usedMILP)
        XCTAssertTrue(result.verified)
        XCTAssertTrue(result.point.allSatisfy { abs($0 - $0.rounded()) < 1e-9 })
    }

    func testActiveSetPolishesConvergedQuadraticPoint() throws {
        let matrix = try QuadraticConstraintMatrix(rows: 1, columns: 2,
            rowPointers: [0, 2], columnIndices: [0, 1], values: [1, 1])
        let problem = QuadraticProblem(quadratic: [[2, 0], [0, 2]], linear: [0, 0],
            constraints: matrix, rowBounds: [.init(lower: 1, upper: 1)],
            variableBounds: [.init(), .init()])
        let solved = try ConvexQuadraticSolver.solve(problem)
        let polished = try QuadraticPolisher.polish(problem, result: solved)
        XCTAssertTrue(polished.attempted)
        XCTAssertTrue(polished.accepted)
        XCTAssertEqual(polished.point[0], 0.5, accuracy: 1e-10)
        XCTAssertEqual(polished.point[1], 0.5, accuracy: 1e-10)
        XCTAssertLessThanOrEqual(polished.objective, solved.objective + 1e-6)
        XCTAssertLessThanOrEqual(polished.maximumRowViolation, 1e-10)
    }
}
