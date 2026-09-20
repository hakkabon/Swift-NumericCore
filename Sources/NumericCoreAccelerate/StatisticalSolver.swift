import Foundation
import NumericCore

/// Result of a weighted least-squares solve for a statistical model.
///
/// `weightedResidualSumOfSquares + penaltyContribution` is the minimized
/// objective. `penaltyContribution` is zero for
/// ``StatisticalSolver/weightedLeastSquares(design:response:weights:)``.
/// The result deliberately reports only quantities that are well-defined
/// without a model-specific degrees-of-freedom or covariance convention.
public struct StatisticalLeastSquaresResult: Sendable, Hashable {
    public let coefficients: [Double]
    /// `Σᵢ wᵢ(yᵢ − xᵢᵀβ)²` over positive-weight observations.
    public let weightedResidualSumOfSquares: Double
    /// `λ‖Pβ‖²`, or zero for an unpenalized solve.
    public let penaltyContribution: Double
    /// Number of rows whose weight was strictly positive.
    public let activeObservationCount: Int

    /// Total minimized weighted/penalized least-squares objective.
    public var objective: Double { weightedResidualSumOfSquares + penaltyContribution }

    fileprivate init(
        coefficients: [Double], weightedResidualSumOfSquares: Double,
        penaltyContribution: Double, activeObservationCount: Int
    ) {
        self.coefficients = coefficients
        self.weightedResidualSumOfSquares = weightedResidualSumOfSquares
        self.penaltyContribution = penaltyContribution
        self.activeObservationCount = activeObservationCount
    }
}

/// Stable array-oriented solver boundary for statistical clients.
///
/// Statistical packages naturally exchange row-major design matrices and
/// arrays, while `NumericCore` stores dense matrices in column-major form.
/// This type owns that conversion and normalizes invalid shapes, LAPACK
/// failures, and rank/definiteness verdicts to `nil`. It lets clients share a
/// numerical contract without importing `Matrix`/`Vector` conversion details
/// at each LOESS, IRLS, or regression call site.
public enum StatisticalSolver {
    /// Solve `min ‖Xβ − y‖₂` by QR.
    ///
    /// Returns nil for invalid shapes, underdetermined/rank-deficient designs,
    /// or a backend failure. Rows are supplied in conventional row-major form.
    public static func leastSquares(design: [[Double]], response: [Double]) -> [Double]? {
        do {
            let matrix = try Matrix<Double>(rows: design)
            let vector = Vector(response)
            guard let solution = try AccelerateBackend.leastSquares(
                design: matrix, response: vector
            ) else { return nil }
            return solution.storage
        } catch {
            return nil
        }
    }

    /// Solve `min Σᵢ wᵢ(yᵢ − xᵢᵀβ)²` by row-scaling into the QR solver.
    ///
    /// Rows with a zero weight are excluded, which is useful for a missing or
    /// masked observation without changing the design's row numbering in the
    /// caller. All values must be finite and weights non-negative. The method
    /// returns `nil` when the positive-weight design is underdetermined or
    /// rank-deficient; it never silently falls back to normal equations.
    public static func weightedLeastSquares(
        design: [[Double]], response: [Double], weights: [Double]
    ) -> StatisticalLeastSquaresResult? {
        return solveWeighted(
            design: design, response: response, weights: weights,
            penaltyRows: [], penaltyWeight: 0
        )
    }

    /// Solve the penalized weighted problem
    /// `min Σᵢ wᵢ(yᵢ − xᵢᵀβ)² + λ‖Pβ‖²` by augmented QR.
    ///
    /// `penaltyRows` is the row-major penalty operator `P`, and
    /// `penaltyWeight` is λ. This is the numerical form needed by penalized
    /// smooth bases and IRLS iterations: it avoids explicitly forming
    /// `XᵀWX + λPᵀP`, whose condition number squares that of the augmented
    /// design. Zero observation weights are excluded; λ must be finite and
    /// strictly positive. `nil` is returned for invalid shapes/non-finite
    /// input or an augmented design that remains rank-deficient.
    public static func penalizedWeightedLeastSquares(
        design: [[Double]], response: [Double], weights: [Double],
        penaltyRows: [[Double]], penaltyWeight: Double
    ) -> StatisticalLeastSquaresResult? {
        guard !penaltyRows.isEmpty else { return nil }
        return solveWeighted(
            design: design, response: response, weights: weights,
            penaltyRows: penaltyRows, penaltyWeight: penaltyWeight
        )
    }

    /// Solve a general square system by QR with the shared rank threshold.
    ///
    /// Returns nil for invalid shapes, singular systems, or backend failures.
    public static func solve(_ matrix: [[Double]], _ response: [Double]) -> [Double]? {
        do {
            let coefficientMatrix = try Matrix<Double>(rows: matrix)
            let vector = Vector(response)
            guard let solution = try AccelerateBackend.solve(coefficientMatrix, vector) else {
                return nil
            }
            return solution.storage
        } catch {
            return nil
        }
    }

    /// Solve a symmetric positive-definite system by Cholesky.
    ///
    /// The caller must supply a symmetric-by-construction matrix. Returns nil
    /// for invalid shapes, non-positive-definite systems, or backend failures.
    public static func solveSPD(_ matrix: [[Double]], _ response: [Double]) -> [Double]? {
        do {
            let coefficientMatrix = try Matrix<Double>(rows: matrix)
            let vector = Vector(response)
            guard let solution = try AccelerateBackend.solveSPD(coefficientMatrix, vector) else {
                return nil
            }
            return solution.storage
        } catch {
            return nil
        }
    }

    private static func solveWeighted(
        design: [[Double]], response: [Double], weights: [Double],
        penaltyRows: [[Double]], penaltyWeight: Double
    ) -> StatisticalLeastSquaresResult? {
        guard design.count == response.count, response.count == weights.count,
              let columnCount = design.first?.count, columnCount > 0,
              design.allSatisfy({ $0.count == columnCount && $0.allSatisfy(\.isFinite) }),
              response.allSatisfy(\.isFinite), weights.allSatisfy({ $0.isFinite && $0 >= 0 })
        else { return nil }

        let isPenalized = !penaltyRows.isEmpty
        guard (!isPenalized || (penaltyWeight.isFinite && penaltyWeight > 0)),
              penaltyRows.allSatisfy({ $0.count == columnCount && $0.allSatisfy(\.isFinite) })
        else { return nil }

        let active = design.indices.filter { weights[$0] > 0 }
        guard active.count >= columnCount else { return nil }

        var augmentedDesign: [[Double]] = []
        var augmentedResponse: [Double] = []
        augmentedDesign.reserveCapacity(active.count + penaltyRows.count)
        augmentedResponse.reserveCapacity(active.count + penaltyRows.count)
        for index in active {
            let scale = sqrt(weights[index])
            let row = design[index].map { scale * $0 }
            let value = scale * response[index]
            guard row.allSatisfy(\.isFinite), value.isFinite else { return nil }
            augmentedDesign.append(row)
            augmentedResponse.append(value)
        }
        if isPenalized {
            let scale = sqrt(penaltyWeight)
            for row in penaltyRows {
                let scaled = row.map { scale * $0 }
                guard scaled.allSatisfy(\.isFinite) else { return nil }
                augmentedDesign.append(scaled)
                augmentedResponse.append(0)
            }
        }

        guard let coefficients = leastSquares(design: augmentedDesign, response: augmentedResponse) else {
            return nil
        }
        let weightedRSS = active.reduce(0.0) { partial, index in
            let residual = response[index] - dot(design[index], coefficients)
            return partial + weights[index] * residual * residual
        }
        let penaltyContribution = penaltyRows.reduce(0.0) { partial, row in
            let value = dot(row, coefficients)
            return partial + penaltyWeight * value * value
        }
        guard weightedRSS.isFinite, penaltyContribution.isFinite,
              (weightedRSS + penaltyContribution).isFinite else { return nil }
        return StatisticalLeastSquaresResult(
            coefficients: coefficients, weightedResidualSumOfSquares: weightedRSS,
            penaltyContribution: penaltyContribution, activeObservationCount: active.count
        )
    }

    private static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
