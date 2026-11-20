import XCTest
import NumericCoreOptimization

final class LPDecompositionTests: XCTestCase {
    func testWorkspaceTransportOrExplicitLegacyError() throws {
        let problem = try SparseLinearProblem(
            objective: [1], rows: 1, columns: 1, rowPointers: [0, 1],
            columnIndices: [0], values: [1], rowBounds: [.init(lower: 2)],
            variableBounds: [.init(lower: 0, upper: 10)])
        guard LPReoptimizationWorkspace.isAvailable else {
            XCTAssertThrowsError(try LPReoptimizationWorkspace(problem: problem)) {
                XCTAssertEqual($0 as? LPDecompositionError, .unsupportedFFI)
            }
            return
        }
        let metadata = LPSubproblemID(name: "recourse", scenario: "winter")
        let workspace = try LPReoptimizationWorkspace(problem: problem, subproblem: metadata)
        let first = try workspace.solve()
        XCTAssertEqual(first.subproblem, metadata)
        XCTAssertEqual(first.status, .optimal)
        XCTAssertEqual(first.variableValues, [2])
        XCTAssertEqual(first.dual?.rowMultipliers, [1])
        XCTAssertFalse(first.usedWarmStart)

        try workspace.installBasis(first.basis)
        try workspace.update(.init(rowBounds: [.init(index: 0, bound: .init(lower: 4))]))
        let second = try workspace.solve()
        XCTAssertEqual(second.variableValues, [4])
        XCTAssertEqual(second.dual?.objectiveBound, 4)
        XCTAssertTrue(second.usedWarmStart)
        XCTAssertThrowsError(try workspace.update(.init(
            objective: [.init(index: -1, value: 0)])))
        XCTAssertEqual(try workspace.solve().variableValues, [4])

        try workspace.update(.init(variableBounds: [.init(index: 0, bound: .init(upper: 1))]))
        let certificate = try XCTUnwrap(workspace.solve().infeasibility)
        XCTAssertGreaterThan(certificate.contradictionMargin, 0)

        let rayProblem = try SparseLinearProblem(
            objective: [-1, 0], rows: 1, columns: 2, rowPointers: [0, 2],
            columnIndices: [0, 1], values: [1, -1], rowBounds: [.init(lower: 0, upper: 0)],
            variableBounds: [.init(lower: 0), .init(lower: 0)])
        let rayReport = try LPReoptimizationWorkspace(problem: rayProblem).solve()
        XCTAssertEqual(rayReport.status, .unbounded)
        let ray = try XCTUnwrap(rayReport.unboundedRay)
        XCTAssertEqual(ray.direction, [1, 1])
        XCTAssertEqual(try LPDecompositionEvidence.unboundedRay(
            problem: rayProblem, anchor: rayReport.variableValues, direction: ray.direction), ray)
        XCTAssertNil(try LPDecompositionEvidence.unboundedRay(
            problem: rayProblem, anchor: rayReport.variableValues, direction: [1, 1 - 1e-10]))
        XCTAssertNil(try LPDecompositionEvidence.unboundedRay(
            problem: rayProblem, anchor: [0, 1e-10], direction: ray.direction))
    }

    func testQuadraticWorkspaceUpdatesAndRetainsConvergence() throws {
        let problem = QuadraticProblem(
            quadratic: [[2]], linear: [-4], constraints: try .empty(columns: 1),
            rowBounds: [], variableBounds: [.init(lower: 0, upper: 10)])
        var workspace = try QuadraticWorkspace(problem: problem)
        let first = try workspace.solve()
        XCTAssertEqual(first.termination, .converged)
        XCTAssertEqual(first.point[0], 2, accuracy: 1e-5)
        XCTAssertLessThan(try workspace.solve().iterations, first.iterations)
        try workspace.update(linear: [-6], constant: 1, rowBounds: [],
                             variableBounds: [.init(lower: 0, upper: 10)])
        let second = try workspace.solve()
        XCTAssertEqual(second.termination, .converged)
        XCTAssertEqual(second.point[0], 3, accuracy: 1e-5)
        XCTAssertThrowsError(try workspace.update(linear: [-99], constant: 1, rowBounds: [],
                                                  variableBounds: [.init(lower: 5, upper: 1)]))
        XCTAssertEqual(workspace.problem.linear, [-6])
    }
}
