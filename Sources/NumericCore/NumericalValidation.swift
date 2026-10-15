import Foundation

/// Mixed absolute/relative acceptance rule shared by validation suites.
public enum ValidationTier: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case smoke, standard, extended

    public static func < (lhs: Self, rhs: Self) -> Bool {
        Self.allCases.firstIndex(of: lhs)! < Self.allCases.firstIndex(of: rhs)!
    }
}

public struct ValidationTolerance: Sendable, Hashable, Codable {
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

public struct ValidationMetric: Sendable, Hashable, Codable {
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

public struct ValidationProvenance: Sendable, Hashable, Codable {
    public let collection: String
    public let problem: String
    public let citation: String
    public let sourceURL: String
    public init(collection: String, problem: String, citation: String, sourceURL: String) {
        self.collection = collection; self.problem = problem
        self.citation = citation; self.sourceURL = sourceURL
    }
}

public struct ValidationCase: Sendable, Hashable, Codable {
    public let id: String
    public let family: String
    public let tier: ValidationTier
    public let name: String
    public let metrics: [ValidationMetric]
    public let provenance: ValidationProvenance?
    public var passed: Bool { !metrics.isEmpty && metrics.allSatisfy(\.passed) }

    public init(id: String? = nil, family: String = "core", tier: ValidationTier = .smoke,
                name: String, metrics: [ValidationMetric],
                provenance: ValidationProvenance? = nil) {
        self.id = id ?? Self.stableIdentifier(name)
        self.family = family
        self.tier = tier
        self.name = name
        self.metrics = metrics
        self.provenance = provenance
    }

    private static func stableIdentifier(_ name: String) -> String {
        var result = "", needsSeparator = false
        for scalar in name.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar); needsSeparator = false
            } else if !needsSeparator, !result.isEmpty {
                result.append("-"); needsSeparator = true
            }
        }
        while result.last == "-" { result.removeLast() }
        return result
    }
}

public struct ValidationReport: Sendable, Hashable, Codable {
    public let cases: [ValidationCase]
    public var passed: Bool { !cases.isEmpty && cases.allSatisfy(\.passed) }
    public var failureCount: Int { cases.filter { !$0.passed }.count }
    public var maximumNormalizedError: Double {
        cases.flatMap(\.metrics).map(\.normalizedError).max() ?? 0
    }

    public init(cases: [ValidationCase]) { self.cases = cases }

    public func filtered(through tier: ValidationTier) -> ValidationReport {
        .init(cases: cases.filter { $0.tier <= tier })
    }

    public func snapshot(implementation: String, tier: ValidationTier) -> ValidationSnapshot {
        .init(implementation: implementation, tier: tier,
              cases: filtered(through: tier).cases)
    }
}

public struct ValidationManifestEntry: Sendable, Hashable, Codable {
    public let id: String
    public let family: String
    public let tier: ValidationTier
    public let name: String
    public let metricNames: [String]
    public let provenance: ValidationProvenance?
}

public struct ValidationRegression: Sendable, Hashable, Codable {
    public let caseID: String
    public let metric: String?
    public let message: String
}

public struct ValidationSnapshot: Sendable, Hashable, Codable {
    public let schemaVersion: Int
    public let implementation: String
    public let tier: ValidationTier
    public let cases: [ValidationCase]

    public init(implementation: String, tier: ValidationTier, cases: [ValidationCase]) {
        schemaVersion = 1
        self.implementation = implementation
        self.tier = tier
        self.cases = cases.sorted { $0.id < $1.id }
    }

    public var manifest: [ValidationManifestEntry] {
        cases.map { validationCase in
            .init(id: validationCase.id, family: validationCase.family,
                  tier: validationCase.tier, name: validationCase.name,
                  metricNames: validationCase.metrics.map(\.name),
                  provenance: validationCase.provenance)
        }
    }

    public var manifestIssues: [String] {
        var issues: [String] = []
        for (index, validationCase) in cases.enumerated() {
            if validationCase.id.isEmpty {
                issues.append("case at index \(index) has an empty identifier")
            }
            if cases[..<index].contains(where: { $0.id == validationCase.id }) {
                issues.append("duplicate case identifier: \(validationCase.id)")
            }
            if validationCase.family.isEmpty {
                issues.append("case \(validationCase.id) has an empty family")
            }
        }
        return issues
    }

    public func jsonData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return try encoder.encode(self)
    }

    public func regressions(against baseline: ValidationSnapshot,
                            normalizedErrorSlack: Double = 0) -> [ValidationRegression] {
        let slack = normalizedErrorSlack.isFinite && normalizedErrorSlack >= 0
            ? normalizedErrorSlack : 0
        var regressions: [ValidationRegression] = []
        for oldCase in baseline.cases {
            guard let newCase = cases.first(where: { $0.id == oldCase.id }) else {
                regressions.append(.init(caseID: oldCase.id, metric: nil,
                                         message: "case missing from current snapshot"))
                continue
            }
            for oldMetric in oldCase.metrics {
                guard let newMetric = newCase.metrics.first(where: { $0.name == oldMetric.name }) else {
                    regressions.append(.init(caseID: oldCase.id, metric: oldMetric.name,
                                             message: "metric missing from current snapshot"))
                    continue
                }
                if oldMetric.passed && !newMetric.passed {
                    regressions.append(.init(caseID: oldCase.id, metric: oldMetric.name,
                                             message: "metric changed from pass to fail"))
                } else if newMetric.normalizedError > oldMetric.normalizedError + slack {
                    regressions.append(.init(caseID: oldCase.id, metric: oldMetric.name,
                                             message: "normalized error exceeded baseline slack"))
                }
            }
        }
        return regressions
    }
}

public struct LinearSystemValidation: Sendable, Hashable, Codable {
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
