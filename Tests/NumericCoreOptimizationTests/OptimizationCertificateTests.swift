import XCTest
@testable import NumericCoreOptimization

final class OptimizationCertificateTests: XCTestCase {
    func testConvexQPCertificateRecomputesKKTConditions() throws {
        let problem = QuadraticProblem(
            quadratic: [[2]], linear: [-4], constraints: try .empty(columns: 1),
            rowBounds: [], variableBounds: [.init(lower: 0, upper: 1)])
        let result = try ConvexQuadraticSolver.solve(
            problem, options: .init(maxIterations: 10_000, rho: 1e-8))
        let certificate = try OptimizationCertifier.certifyConvexQP(
            problem: problem, result: result)
        XCTAssertEqual(certificate.claim, .optimality, "\(certificate)")
        XCTAssertTrue(certificate.verified)

        let corrupted = QuadraticResult(
            point: [2], objective: result.objective, rowActivity: [], rowDual: [],
            variableDual: result.variableDual, iterations: result.iterations,
            termination: result.termination, primalResidual: result.primalResidual,
            dualResidual: result.dualResidual, stationarityNorm: result.stationarityNorm,
            maximumRowViolation: 0, maximumVariableViolation: 1)
        XCTAssertEqual(try OptimizationCertifier.certifyConvexQP(
            problem: problem, result: corrupted).claim, .rejected)
    }

    func testLinearCertificateDoesNotInventDualEvidence() throws {
        let problem = try SparseLinearProblem(
            objective: [1], rows: 0, columns: 1, rowPointers: [0],
            columnIndices: [], values: [], rowBounds: [],
            variableBounds: [.init(lower: 2, upper: 2)])
        let result = try ProductionLinearSolver.solve(problem)
        let feasible = try OptimizationCertifier.certifyLinear(problem: problem, result: result)
        XCTAssertEqual(feasible.claim, .feasibility)
        XCTAssertTrue(feasible.verified)
        let optimal = try OptimizationCertifier.certifyLinear(
            problem: problem, result: result, globalGap: 0)
        XCTAssertEqual(optimal.claim, .optimality)
        XCTAssertTrue(optimal.verified)
        let rejected = try OptimizationCertifier.certifyLinear(
            problem: problem, result: result, globalGap: .nan)
        XCTAssertEqual(rejected.claim, .rejected)
        XCTAssertFalse(rejected.finite)
    }
}
