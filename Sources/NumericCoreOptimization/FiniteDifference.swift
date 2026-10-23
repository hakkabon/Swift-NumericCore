import Foundation

public struct FiniteDifferenceResult: Sendable, Hashable {
    public let gradient: [Double]
    public let evaluations: Int
}

public enum FiniteDifference {
    public static func centralGradient(
        at point: [Double], relativeStep: Double = 1e-6,
        objective: ([Double]) throws -> Double
    ) throws -> FiniteDifferenceResult {
        guard !point.isEmpty, point.allSatisfy(\.isFinite),
              relativeStep.isFinite, relativeStep > 0 else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "finite-difference point and step must be finite and non-empty")
        }
        var gradient = [Double](repeating: 0, count: point.count)
        for index in point.indices {
            let step = relativeStep * max(abs(point[index]), 1)
            var plus = point, minus = point
            plus[index] += step
            minus[index] -= step
            let high = try objective(plus), low = try objective(minus)
            guard high.isFinite, low.isFinite else {
                throw NonlinearOptimizationError.invalidEvaluation(
                    "finite-difference objective returned a non-finite value")
            }
            gradient[index] = (high - low) / (2 * step)
        }
        return .init(gradient: gradient, evaluations: 2 * point.count)
    }
}
