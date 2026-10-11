/// Mixed absolute/relative acceptance rule shared by validation suites.
public struct ValidationTolerance: Sendable, Hashable {
    public var absolute: Double
    public var relative: Double

    public init(absolute: Double = 1e-10, relative: Double = 1e-8) {
        self.absolute = absolute
        self.relative = relative
    }

    public var isValid: Bool {
        absolute.isFinite && absolute >= 0 && relative.isFinite && relative >= 0
    }

    public func threshold(observed: Double, reference: Double) -> Double {
        guard isValid, observed.isFinite, reference.isFinite else { return .nan }
        return absolute + relative * max(abs(observed), abs(reference))
    }
}

public struct ValidationMetric: Sendable, Hashable {
    public let name: String
    public let observed: Double
    public let reference: Double
    public let absoluteError: Double
    public let allowedError: Double
    public let normalizedError: Double
    public let passed: Bool

    public init(name: String, observed: Double, reference: Double,
                tolerance: ValidationTolerance = .init()) {
        self.name = name
        self.observed = observed
        self.reference = reference
        absoluteError = abs(observed - reference)
        allowedError = tolerance.threshold(observed: observed, reference: reference)
        if allowedError > 0 { normalizedError = absoluteError / allowedError }
        else { normalizedError = absoluteError == 0 ? 0 : .infinity }
        passed = absoluteError.isFinite && allowedError.isFinite && absoluteError <= allowedError
    }
}

public struct ValidationCase: Sendable, Hashable {
    public let name: String
    public let metrics: [ValidationMetric]
    public var passed: Bool { !metrics.isEmpty && metrics.allSatisfy(\.passed) }

    public init(name: String, metrics: [ValidationMetric]) {
        self.name = name
        self.metrics = metrics
    }
}

public struct ValidationReport: Sendable, Hashable {
    public let cases: [ValidationCase]
    public var passed: Bool { !cases.isEmpty && cases.allSatisfy(\.passed) }
    public var failureCount: Int { cases.filter { !$0.passed }.count }
    public var maximumNormalizedError: Double {
        cases.flatMap(\.metrics).map(\.normalizedError).max() ?? 0
    }

    public init(cases: [ValidationCase]) { self.cases = cases }
}

public struct LinearSystemValidation: Sendable, Hashable {
    public let finite: Bool
    public let residualInfinityNorm: Double
    public let relativeResidual: Double
    public let backwardError: Double

    public func isVerified(tolerance: Double) -> Bool {
        finite && tolerance.isFinite && tolerance >= 0 && backwardError <= tolerance
    }
}

public enum NumericalValidation {
    /// Independently recompute normwise residual and backward error for `A x = b`.
    public static func linearSystem(matrix: [[Double]], solution: [Double],
                                    rightHandSide: [Double]) -> LinearSystemValidation {
        let valid = matrix.count == rightHandSide.count
            && matrix.allSatisfy { $0.count == solution.count }
            && matrix.flatMap { $0 }.allSatisfy(\.isFinite)
            && solution.allSatisfy(\.isFinite) && rightHandSide.allSatisfy(\.isFinite)
        guard valid else {
            return .init(finite: false, residualInfinityNorm: .infinity,
                         relativeResidual: .infinity, backwardError: .infinity)
        }
        var residualNorm = 0.0, matrixNorm = 0.0
        for (row, target) in zip(matrix, rightHandSide) {
            let fitted = zip(row, solution).reduce(0.0) { $0 + $1.0 * $1.1 }
            residualNorm = max(residualNorm, abs(fitted - target))
            matrixNorm = max(matrixNorm, row.reduce(0) { $0 + abs($1) })
        }
        let solutionNorm = solution.map(abs).max() ?? 0
        let rhsNorm = rightHandSide.map(abs).max() ?? 0
        let relative = residualNorm / max(rhsNorm, 1e-300)
        let backward = residualNorm / max(matrixNorm * solutionNorm + rhsNorm, 1e-300)
        return .init(finite: residualNorm.isFinite && backward.isFinite,
                     residualInfinityNorm: residualNorm,
                     relativeResidual: relative, backwardError: backward)
    }

    /// Stable pseudo-random relative perturbations for repeatable sensitivity tests.
    public static func perturb(_ values: [Double], seed: UInt64,
                               relativeMagnitude: Double) -> [Double] {
        guard relativeMagnitude.isFinite, relativeMagnitude >= 0 else {
            return [Double](repeating: .nan, count: values.count)
        }
        var state = seed
        return values.map { value in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(UInt64(1) << 53)
            return value + (2 * unit - 1) * relativeMagnitude * max(abs(value), 1)
        }
    }
}
