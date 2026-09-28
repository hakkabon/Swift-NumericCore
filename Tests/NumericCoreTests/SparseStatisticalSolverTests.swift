import XCTest
@testable import NumericCore
@testable import NumericCoreAccelerate
@testable import NumericCoreSparse

final class SparseStatisticalSolverTests: XCTestCase {
    func testSparseWeightedLeastSquaresMatchesDenseQRContract() throws {
        let sparseDesign = try SparseMatrix<Double>(
            rows: 4,
            cols: 2,
            rowPointers: [0, 1, 3, 5, 7],
            columnIndices: [0, 0, 1, 0, 1, 0, 1],
            values: [1, 1, 1, 1, 2, 1, 3]
        )
        let response = [1.0, 3, 5, 100]
        let weights = [1.0, 1, 1, 0]
        let dense = try XCTUnwrap(StatisticalSolver.weightedLeastSquares(
            design: [[1, 0], [1, 1], [1, 2], [1, 3]],
            response: response,
            weights: weights
        ))
        let sparse = try SparseStatisticalSolver.weightedLeastSquares(
            design: sparseDesign,
            response: response,
            weights: weights,
            maxIterations: 20,
            tolerance: 1e-12
        )

        XCTAssertTrue(sparse.converged)
        assertEqual(sparse.coefficients, dense.coefficients, accuracy: 1e-10)
        XCTAssertEqual(
            sparse.weightedResidualSumOfSquares,
            dense.weightedResidualSumOfSquares,
            accuracy: 1e-18
        )
        XCTAssertEqual(sparse.penaltyContribution, dense.penaltyContribution, accuracy: 1e-18)
        XCTAssertEqual(sparse.objective, dense.objective, accuracy: 1e-18)
    }

    func testSparsePenalizedLeastSquaresMatchesDenseQRContract() throws {
        let design = try SparseMatrix<Double>(
            rows: 3,
            cols: 2,
            rowPointers: [0, 2, 4, 6],
            columnIndices: [0, 1, 0, 1, 0, 1],
            values: [1, 1, 1, 1, 1, 1]
        )
        let penalty = try SparseMatrix<Double>(
            rows: 2,
            cols: 2,
            rowPointers: [0, 1, 2],
            columnIndices: [0, 1],
            values: [1, 1]
        )
        let dense = try XCTUnwrap(StatisticalSolver.penalizedWeightedLeastSquares(
            design: [[1, 1], [1, 1], [1, 1]],
            response: [2, 2, 2],
            weights: [1, 1, 1],
            penaltyRows: [[1, 0], [0, 1]],
            penaltyWeight: 1
        ))
        let sparse = try SparseStatisticalSolver.penalizedWeightedLeastSquares(
            design: design,
            response: [2, 2, 2],
            weights: [1, 1, 1],
            penalty: penalty,
            penaltyWeight: 1,
            maxIterations: 20,
            tolerance: 1e-12
        )

        XCTAssertTrue(sparse.converged)
        assertEqual(sparse.coefficients, dense.coefficients, accuracy: 1e-10)
        XCTAssertEqual(
            sparse.weightedResidualSumOfSquares,
            dense.weightedResidualSumOfSquares,
            accuracy: 1e-10
        )
        XCTAssertEqual(sparse.penaltyContribution, dense.penaltyContribution, accuracy: 1e-10)
        XCTAssertEqual(sparse.objective, dense.objective, accuracy: 1e-10)
    }

    func testSparseStatisticalSolverSurfacesInvalidInputs() throws {
        let design = try SparseMatrix<Double>(
            rows: 1, cols: 1, rowPointers: [0, 1], columnIndices: [0], values: [1]
        )

        XCTAssertThrowsError(try SparseStatisticalSolver.weightedLeastSquares(
            design: design,
            response: [1],
            weights: [-1],
            maxIterations: 10,
            tolerance: 1e-8
        ))
        XCTAssertThrowsError(try SparseStatisticalSolver.weightedLeastSquares(
            design: design,
            response: [1],
            weights: [1],
            maxIterations: 0,
            tolerance: 1e-8
        ))
    }

    func testSparsePenalizedBinomialIRLSConvergesOnARealisticWorkflow() throws {
        // Intercept plus one covariate, with a small ridge penalty on slope.
        let design = try SparseMatrix<Double>(
            rows: 8, cols: 2,
            rowPointers: [0, 2, 4, 6, 8, 10, 12, 14, 16],
            columnIndices: Array(repeating: [0, 1], count: 8).flatMap { $0 },
            values: [-3, -2, -1, -0.25, 0.25, 1, 2, 3].flatMap { [1, $0] }
        )
        let penalty = try SparseMatrix<Double>(
            rows: 1, cols: 2, rowPointers: [0, 1], columnIndices: [1], values: [1]
        )
        let result = try SparseIRLSSolver.fit(
            design: design,
            response: [0, 0, 0, 0, 1, 1, 1, 1],
            penalty: penalty,
            penaltyWeight: 0.1,
            family: .binomialLogit,
            maxIterations: 30,
            coefficientTolerance: 1e-9,
            leastSquaresTolerance: 1e-12
        )

        XCTAssertTrue(result.converged)
        XCTAssertLessThan(result.iterations, 30)
        XCTAssertEqual(result.coefficients[0], 0, accuracy: 1e-8)
        XCTAssertGreaterThan(result.coefficients[1], 0)
        XCTAssertTrue(result.deviance.isFinite)
        XCTAssertTrue(result.lastLeastSquaresResult.converged)
    }

    func testSparseIRLSValidatesFamilyDomain() throws {
        let identity = try SparseMatrix<Double>(
            rows: 1, cols: 1, rowPointers: [0, 1], columnIndices: [0], values: [1]
        )
        XCTAssertThrowsError(try SparseIRLSSolver.fit(
            design: identity, response: [-1], penalty: identity,
            penaltyWeight: 1, family: .poissonLog
        ))
    }
}

private func assertEqual(
    _ actual: [Double], _ expected: [Double], accuracy: Double,
    file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (lhs, rhs) in zip(actual, expected) {
        XCTAssertEqual(lhs, rhs, accuracy: accuracy, file: file, line: line)
    }
}
