import Foundation

public struct DerivativeCheckReport: Sendable, Hashable {
    public let maximumAbsoluteError: Double
    public let maximumRelativeError: Double
    public let worstRow: Int
    public let worstColumn: Int
    public let passed: Bool
    public let evaluations: Int
}

public enum DerivativeCheck {
    public static func gradient(
        at point: [Double], analytic: [Double], relativeStep: Double = 1e-6,
        tolerance: Double = 1e-5, objective: ([Double]) throws -> Double
    ) throws -> DerivativeCheckReport {
        guard !point.isEmpty, analytic.count == point.count else {
            throw NonlinearOptimizationError.invalidEvaluation("gradient check dimensions do not agree")
        }
        let numerical = try centralDifference(
            point: point, rows: 1, relativeStep: relativeStep
        ) { [try objective($0)] }
        return compare(analytic: [analytic], numerical: numerical,
                       tolerance: tolerance, evaluations: 2 * point.count)
    }

    public static func jacobian(
        at point: [Double], analytic: [[Double]], relativeStep: Double = 1e-6,
        tolerance: Double = 1e-5, residuals: ([Double]) throws -> [Double]
    ) throws -> DerivativeCheckReport {
        guard !point.isEmpty, !analytic.isEmpty,
              analytic.allSatisfy({ $0.count == point.count }) else {
            throw NonlinearOptimizationError.invalidEvaluation("Jacobian check dimensions do not agree")
        }
        let numerical = try centralDifference(
            point: point, rows: analytic.count, relativeStep: relativeStep, values: residuals
        )
        return compare(analytic: analytic, numerical: numerical,
                       tolerance: tolerance, evaluations: 2 * point.count)
    }

    private static func centralDifference(
        point: [Double], rows: Int, relativeStep: Double,
        values: ([Double]) throws -> [Double]
    ) throws -> [[Double]] {
        guard relativeStep.isFinite, relativeStep > 0 else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "derivative-check step must be finite and positive")
        }
        var derivative = [[Double]](
            repeating: [Double](repeating: 0, count: point.count), count: rows)
        for column in point.indices {
            let step = relativeStep * max(abs(point[column]), 1)
            var plus = point; plus[column] += step
            var minus = point; minus[column] -= step
            let high = try values(plus)
            let low = try values(minus)
            guard high.count == rows, low.count == rows,
                  high.allSatisfy(\.isFinite), low.allSatisfy(\.isFinite) else {
                throw NonlinearOptimizationError.invalidEvaluation(
                    "finite-difference callback shape changed or returned non-finite values")
            }
            for row in 0..<rows { derivative[row][column] = (high[row] - low[row]) / (2 * step) }
        }
        return derivative
    }

    private static func compare(analytic: [[Double]], numerical: [[Double]],
                                tolerance: Double, evaluations: Int) -> DerivativeCheckReport {
        var maximumAbsolute = 0.0
        var maximumRelative = 0.0
        var worst = (0, 0)
        for row in analytic.indices { for column in analytic[row].indices {
            let absolute = abs(analytic[row][column] - numerical[row][column])
            let relative = absolute / max(abs(analytic[row][column]), abs(numerical[row][column]), 1)
            maximumAbsolute = max(maximumAbsolute, absolute)
            if relative > maximumRelative {
                maximumRelative = relative; worst = (row, column)
            }
        } }
        return .init(maximumAbsoluteError: maximumAbsolute,
                     maximumRelativeError: maximumRelative,
                     worstRow: worst.0, worstColumn: worst.1,
                     passed: tolerance.isFinite && tolerance >= 0 && maximumRelative <= tolerance,
                     evaluations: evaluations)
    }
}
