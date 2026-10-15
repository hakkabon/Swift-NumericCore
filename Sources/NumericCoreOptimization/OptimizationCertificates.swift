import Foundation

public enum CertificateClaim: Sendable, Hashable {
    case optimality, feasibility, candidate, rejected
}

public struct CertificateTolerance: Sendable, Hashable {
    public var feasibility: Double
    public var integrality: Double
    public var stationarity: Double
    public var complementarity: Double
    public var objective: Double
    public var gap: Double
    public var activeSet: Double

    public init(feasibility: Double = 1e-5, integrality: Double = 1e-7,
                stationarity: Double = 1e-6, complementarity: Double = 1e-5,
                objective: Double = 1e-8, gap: Double = 1e-7,
                activeSet: Double = 1e-5) {
        self.feasibility = feasibility; self.integrality = integrality
        self.stationarity = stationarity; self.complementarity = complementarity
        self.objective = objective; self.gap = gap; self.activeSet = activeSet
    }

    fileprivate var isValid: Bool {
        [feasibility, integrality, stationarity, complementarity, objective, gap, activeSet]
            .allSatisfy { $0.isFinite && $0 >= 0 }
    }
}

public struct CertificateMetric: Sendable, Hashable {
    public let name: String
    public let value: Double
    public let tolerance: Double
    public var passed: Bool { value.isFinite && value <= tolerance }
}

public struct OptimizationCertificate: Sendable, Hashable {
    public let claim: CertificateClaim
    public let finite: Bool
    public let metrics: [CertificateMetric]
    public let warnings: [String]
    public var verified: Bool {
        finite && (claim == .optimality || claim == .feasibility)
            && !metrics.isEmpty && metrics.allSatisfy(\.passed)
    }
}

public enum OptimizationCertifier {
    public static func certifyLinear(problem: SparseLinearProblem,
                                     result: ProductionLinearResult,
                                     globalGap: Double? = nil,
                                     tolerance: CertificateTolerance = .init()) throws
        -> OptimizationCertificate {
        try validate(tolerance)
        let diagnostics = result.diagnostics
        var metrics = [
            metric("row feasibility", diagnostics.maximumRowViolation, tolerance.feasibility),
            metric("variable feasibility", diagnostics.maximumVariableViolation, tolerance.feasibility),
            metric("integrality", diagnostics.maximumIntegralityViolation, tolerance.integrality),
            metric("objective reconstruction", diagnostics.objectiveError, tolerance.objective),
        ]
        if let globalGap { metrics.append(metric("global bound gap", abs(globalGap), tolerance.gap)) }
        let finite = diagnostics.finite && metrics.allSatisfy { $0.value.isFinite }
        guard result.status == .optimal, finite, metrics.allSatisfy(\.passed) else {
            return .init(claim: .rejected, finite: finite, metrics: metrics, warnings: [])
        }
        if globalGap != nil {
            return .init(claim: .optimality, finite: true, metrics: metrics, warnings: [])
        }
        return .init(claim: .feasibility, finite: true, metrics: metrics,
                     warnings: ["dual or global-bound evidence unavailable; certifying feasibility only"])
    }

    public static func certifyConvexQP(problem: QuadraticProblem, result: QuadraticResult,
                                       tolerance: CertificateTolerance = .init()) throws
        -> OptimizationCertificate {
        try validate(tolerance); try problem.validate()
        let n = problem.linear.count, m = problem.rowBounds.count
        guard result.point.count == n, result.rowDual.count == m,
              result.variableDual.count == n else {
            return .init(claim: .rejected, finite: false, metrics: [],
                         warnings: ["QP primal/dual dimensions do not agree"])
        }
        var activity = [Double](repeating: 0, count: m)
        var gradient = problem.linear
        for i in 0..<n {
            gradient[i] += zip(problem.quadratic[i], result.point).reduce(0) { $0 + $1.0 * $1.1 }
        }
        for row in 0..<m {
            for index in problem.constraints.rowPointers[row]..<problem.constraints.rowPointers[row + 1] {
                let column = problem.constraints.columnIndices[index]
                let value = problem.constraints.values[index]
                activity[row] += value * result.point[column]
                gradient[column] += value * result.rowDual[row]
            }
        }
        for i in 0..<n { gradient[i] += result.variableDual[i] }
        var complementarity = 0.0, dualViolation = 0.0, activeRows: [[Double]] = []
        for row in 0..<m {
            let evidence = dualEvidence(activity[row], problem.rowBounds[row],
                                        result.rowDual[row], tolerance.activeSet)
            complementarity = max(complementarity, evidence.product)
            dualViolation = max(dualViolation, evidence.signError)
            if evidence.active {
                var values = [Double](repeating: 0, count: n)
                for index in problem.constraints.rowPointers[row]..<problem.constraints.rowPointers[row + 1] {
                    values[problem.constraints.columnIndices[index]] = problem.constraints.values[index]
                }
                activeRows.append(values)
            }
        }
        for i in 0..<n {
            let evidence = dualEvidence(result.point[i], problem.variableBounds[i],
                                        result.variableDual[i], tolerance.activeSet)
            complementarity = max(complementarity, evidence.product)
            dualViolation = max(dualViolation, evidence.signError)
            if evidence.active { var row = [Double](repeating: 0, count: n); row[i] = 1; activeRows.append(row) }
        }
        let metrics = [
            metric("row feasibility", zip(activity, problem.rowBounds).map(boundViolation).max() ?? 0,
                   tolerance.feasibility),
            metric("variable feasibility", zip(result.point, problem.variableBounds)
                    .map(boundViolation).max() ?? 0, tolerance.feasibility),
            metric("stationarity", gradient.map(abs).max() ?? 0, tolerance.stationarity),
            metric("complementarity", complementarity, tolerance.complementarity),
            metric("dual sign feasibility", dualViolation, tolerance.complementarity),
            metric("objective reconstruction", abs(problem.objective(at: result.point) - result.objective),
                   tolerance.objective),
        ]
        let finite = result.point.allSatisfy(\.isFinite) && result.rowDual.allSatisfy(\.isFinite)
            && result.variableDual.allSatisfy(\.isFinite) && metrics.allSatisfy { $0.value.isFinite }
        let rank = numericalRank(activeRows, tolerance: tolerance.activeSet)
        var warnings: [String] = []
        if rank < activeRows.count { warnings.append("active constraints are linearly dependent") }
        if activeRows.count > n { warnings.append("active set is overdetermined") }
        return .init(claim: finite && metrics.allSatisfy(\.passed) ? .optimality : .rejected,
                     finite: finite, metrics: metrics, warnings: warnings)
    }

    private static func metric(_ name: String, _ value: Double, _ tolerance: Double)
        -> CertificateMetric { .init(name: name, value: value, tolerance: tolerance) }
    private static func validate(_ tolerance: CertificateTolerance) throws {
        guard tolerance.isValid else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "certificate tolerances must be finite and nonnegative")
        }
    }
}

private func boundViolation(_ pair: (Double, ParameterBound)) -> Double {
    max(pair.1.lower.map { $0 - pair.0 } ?? 0, pair.1.upper.map { pair.0 - $0 } ?? 0, 0)
}
private func dualEvidence(_ value: Double, _ bound: ParameterBound, _ dual: Double,
                          _ activeTolerance: Double)
    -> (product: Double, signError: Double, active: Bool) {
    let lowerSlack = bound.lower.map { value - $0 }, upperSlack = bound.upper.map { $0 - value }
    if dual == 0 {
        let slack = min(lowerSlack ?? .infinity, upperSlack ?? .infinity)
        return (0, 0, slack.isFinite && abs(slack) <= activeTolerance)
    }
    let slack: Double
    if dual < 0 { slack = lowerSlack ?? .infinity }
    else if dual > 0 { slack = upperSlack ?? .infinity }
    else { slack = .infinity }
    let signError = (dual < 0 && bound.lower == nil) || (dual > 0 && bound.upper == nil)
        ? abs(dual) : 0
    return (abs(dual * slack), signError, abs(slack) <= activeTolerance)
}
private func numericalRank(_ source: [[Double]], tolerance: Double) -> Int {
    guard !source.isEmpty else { return 0 }
    var rows = source, rank = 0
    for column in rows[0].indices {
        guard let pivot = (rank..<rows.count).max(by: { abs(rows[$0][column]) < abs(rows[$1][column]) }),
              abs(rows[pivot][column]) > tolerance else { continue }
        rows.swapAt(rank, pivot); let diagonal = rows[rank][column]
        if rank + 1 < rows.count { for row in rank + 1..<rows.count {
            let factor = rows[row][column] / diagonal
            for item in column..<rows[row].count { rows[row][item] -= factor * rows[rank][item] }
        }}
        rank += 1; if rank == rows.count { break }
    }
    return rank
}
