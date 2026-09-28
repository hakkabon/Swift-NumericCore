import Foundation
import NumericCore

/// Scale-aware tolerance used when a numerical decision cannot be exact.
///
/// The effective threshold is `max(absolute, relative * scale * dimension)`.
/// Keeping both components explicit makes a decision reproducible while the
/// dimension factor prevents the default from pretending accumulated floating-
/// point error is independent of problem size.
public struct NumericalTolerance: Sendable, Hashable {
    public let absolute: Double
    public let relative: Double

    public init(absolute: Double = 0, relative: Double = Double.ulpOfOne) {
        self.absolute = absolute
        self.relative = relative
    }

    public var isValid: Bool {
        absolute.isFinite && absolute >= 0 && relative.isFinite && relative >= 0
    }

    public static let scaleAware = NumericalTolerance()

    public static func absolute(_ value: Double) -> NumericalTolerance {
        NumericalTolerance(absolute: value, relative: 0)
    }

    public func threshold(scale: Double, dimension: Int) -> Double {
        guard isValid, scale.isFinite else { return .nan }
        return max(absolute, relative * abs(scale) * Double(max(dimension, 1)))
    }
}

/// Why a direct or least-squares solve did or did not produce an accepted
/// solution. Shape errors and LAPACK failures remain thrown errors; these are
/// numerical verdicts for an otherwise valid problem.
public enum LinearSolveTermination: Sendable, Hashable {
    case converged
    case rankDeficient
    case singular
    case notPositiveDefinite
    case residualCheckFailed
}

/// Structured diagnostics for dense linear solves.
public struct LinearSolveReport {
    public let solution: Vector<Double>?
    public let termination: LinearSolveTermination
    public let residualNorm: Double?
    public let relativeResidual: Double?
    public let estimatedRank: Int?
    public let decisionThreshold: Double?

    public var converged: Bool { termination == .converged }

    init(
        solution: Vector<Double>?,
        termination: LinearSolveTermination,
        residualNorm: Double? = nil,
        relativeResidual: Double? = nil,
        estimatedRank: Int? = nil,
        decisionThreshold: Double? = nil
    ) {
        self.solution = solution
        self.termination = termination
        self.residualNorm = residualNorm
        self.relativeResidual = relativeResidual
        self.estimatedRank = estimatedRank
        self.decisionThreshold = decisionThreshold
    }
}

extension AccelerateBackend {
    static func residualDiagnostics(
        matrix: Matrix<Double>, solution: Vector<Double>, response: Vector<Double>
    ) -> (norm: Double, relative: Double) {
        var residualSquared = 0.0
        var matrixInfinityNorm = 0.0
        for row in 0..<matrix.rows {
            var fitted = 0.0
            var rowSum = 0.0
            for column in 0..<matrix.cols {
                let value = matrix[row, column]
                fitted += value * solution[column]
                rowSum += abs(value)
            }
            let residual = fitted - response[row]
            residualSquared += residual * residual
            matrixInfinityNorm = max(matrixInfinityNorm, rowSum)
        }
        let residualNorm = sqrt(residualSquared)
        let solutionNorm = sqrt(solution.storage.reduce(0) { $0 + $1 * $1 })
        let responseNorm = sqrt(response.storage.reduce(0) { $0 + $1 * $1 })
        let denominator = matrixInfinityNorm * solutionNorm + responseNorm
        let relative = denominator > 0 ? residualNorm / denominator : residualNorm
        return (residualNorm, relative)
    }
}
