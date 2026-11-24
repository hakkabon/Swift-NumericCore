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
        let widerProblem = try SparseLinearProblem(
            objective: [1], rows: 0, columns: 1, rowPointers: [0],
            columnIndices: [], values: [], rowBounds: [],
            variableBounds: [.init(lower: 0, upper: 2)])
        let supplied = try OptimizationCertifier.certifyLinear(
            problem: widerProblem, result: result, globalGap: 0)
        XCTAssertEqual(supplied.claim, .feasibility)
        XCTAssertTrue(supplied.verified)
        XCTAssertEqual(supplied.metrics.last?.name, "caller-supplied gap")
        for gap in [Double.nan, -1e-12, 1e-3] {
            let rejected = try OptimizationCertifier.certifyLinear(
                problem: widerProblem, result: result, globalGap: gap)
            XCTAssertEqual(rejected.claim, .rejected)
            XCTAssertEqual(rejected.finite, gap.isFinite)
        }

        let incompatibleProblem = try SparseLinearProblem(
            objective: [1], rows: 1, columns: 1, rowPointers: [0, 1],
            columnIndices: [0], values: [1], rowBounds: [.init(lower: 3)],
            variableBounds: [.init()])
        let incompatible = try OptimizationCertifier.certifyLinear(problem: incompatibleProblem, result: result)
        XCTAssertEqual(incompatible.claim, .rejected)
        XCTAssertEqual(incompatible.metrics.first?.value, 1)
    }

    func testConvexQPRejectsNonfiniteReconstructedStationarity() throws {
        let large = Double.greatestFiniteMagnitude
        let constraints = try QuadraticConstraintMatrix(
            rows: 2, columns: 2, rowPointers: [0, 1, 2], columnIndices: [1, 1], values: [large, large])
        let problem = QuadraticProblem(
            quadratic: [[0, 0], [0, 0]], linear: [0, 0], constraints: constraints,
            rowBounds: Array(repeating: .init(lower: 0, upper: 0), count: 2),
            variableBounds: [.init(), .init()])
        let result = QuadraticResult(
            point: [0, 0], objective: 0, rowActivity: [0, 0], rowDual: [2, -2],
            variableDual: [0, 0], iterations: 0, termination: .converged,
            primalResidual: 0, dualResidual: 0, stationarityNorm: 0,
            maximumRowViolation: 0, maximumVariableViolation: 0)
        let certificate = try OptimizationCertifier.certifyConvexQP(problem: problem, result: result)
        XCTAssertEqual(certificate.claim, .rejected)
        XCTAssertFalse(certificate.finite)
    }
}
