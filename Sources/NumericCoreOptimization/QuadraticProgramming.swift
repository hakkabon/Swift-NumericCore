import Foundation

public struct QuadraticConstraintMatrix: Sendable, Hashable {
    public let rows: Int
    public let columns: Int
    public let rowPointers: [Int]
    public let columnIndices: [Int]
    public let values: [Double]

    public init(rows: Int, columns: Int, rowPointers: [Int],
                columnIndices: [Int], values: [Double]) throws {
        guard rows >= 0, columns >= 0, rowPointers.count == rows + 1,
              columnIndices.count == values.count, rowPointers.first == 0,
              rowPointers.last == values.count,
              zip(rowPointers, rowPointers.dropFirst()).allSatisfy({ $0 <= $1 }),
              rowPointers.allSatisfy({ (0...values.count).contains($0) }),
              columnIndices.allSatisfy({ (0..<columns).contains($0) }),
              values.allSatisfy(\.isFinite) else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid QP constraint CSR matrix")
        }
        self.rows = rows; self.columns = columns; self.rowPointers = rowPointers
        self.columnIndices = columnIndices; self.values = values
    }

    public static func empty(columns: Int) throws -> Self {
        try .init(rows: 0, columns: columns, rowPointers: [0], columnIndices: [], values: [])
    }

    fileprivate func dense() -> [[Double]] {
        var result = [[Double]](repeating: [Double](repeating: 0, count: columns), count: rows)
        for row in 0..<rows {
            for index in rowPointers[row]..<rowPointers[row + 1] {
                result[row][columnIndices[index]] += values[index]
            }
        }
        return result
    }
}

public struct QuadraticProblem: Sendable, Hashable {
    public let quadratic: [[Double]]
    public let linear: [Double]
    public let constant: Double
    public let constraints: QuadraticConstraintMatrix
    public let rowBounds: [ParameterBound]
    public let variableBounds: [ParameterBound]

    public init(quadratic: [[Double]], linear: [Double], constant: Double = 0,
                constraints: QuadraticConstraintMatrix, rowBounds: [ParameterBound],
                variableBounds: [ParameterBound]) {
        self.quadratic = quadratic; self.linear = linear; self.constant = constant
        self.constraints = constraints; self.rowBounds = rowBounds
        self.variableBounds = variableBounds
    }

    public func validate(convexityTolerance: Double = 1e-10) throws {
        let n = linear.count
        guard n > 0, quadratic.count == n, quadratic.allSatisfy({ $0.count == n }),
              constraints.columns == n, constraints.rows == rowBounds.count,
              variableBounds.count == n, constant.isFinite,
              linear.allSatisfy(\.isFinite), quadratic.joined().allSatisfy(\.isFinite),
              convexityTolerance.isFinite, convexityTolerance >= 0,
              rowBounds.allSatisfy(qpValidBound), variableBounds.allSatisfy(qpValidBound) else {
            throw NonlinearOptimizationError.invalidConfiguration("QP dimensions, bounds, or coefficients are invalid")
        }
        for i in 0..<n { for j in 0..<i {
            let scale = max(1, abs(quadratic[i][j]), abs(quadratic[j][i]))
            guard abs(quadratic[i][j] - quadratic[j][i]) <= convexityTolerance * scale else {
                throw NonlinearOptimizationError.invalidConfiguration("QP Hessian must be symmetric")
            }
        }}
        var shifted = quadratic
        for index in 0..<n { shifted[index][index] += max(convexityTolerance, 1e-14) }
        guard qpCholesky(shifted) != nil else {
            throw NonlinearOptimizationError.invalidConfiguration("QP Hessian must be positive semidefinite")
        }
    }

    public func objective(at point: [Double]) -> Double {
        var quadraticValue = 0.0
        for index in point.indices { quadraticValue += point[index] * qpDot(quadratic[index], point) }
        return constant + qpDot(linear, point) + 0.5 * quadraticValue
    }
}

public struct QuadraticOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var rho: Double
    public var absoluteTolerance: Double
    public var relativeTolerance: Double
    public var convexityTolerance: Double
    public init(maxIterations: Int = 10_000, rho: Double = 1,
                absoluteTolerance: Double = 1e-7, relativeTolerance: Double = 1e-6,
                convexityTolerance: Double = 1e-10) {
        self.maxIterations = maxIterations; self.rho = rho
        self.absoluteTolerance = absoluteTolerance; self.relativeTolerance = relativeTolerance
        self.convexityTolerance = convexityTolerance
    }
}

public struct QuadraticWarmStart: Sendable, Hashable {
    public let primal: [Double]
    public let rowDual: [Double]
    public let variableDual: [Double]
    public init(primal: [Double], rowDual: [Double], variableDual: [Double]) {
        self.primal = primal; self.rowDual = rowDual; self.variableDual = variableDual
    }
}

public enum QuadraticTermination: Sendable, Hashable {
    case converged, iterationLimit, numericalFailure, cancelled
}

public struct QuadraticResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let rowActivity: [Double]
    public let rowDual: [Double]
    public let variableDual: [Double]
    public let iterations: Int
    public let termination: QuadraticTermination
    public let primalResidual: Double
    public let dualResidual: Double
    public let stationarityNorm: Double
    public let maximumRowViolation: Double
    public let maximumVariableViolation: Double

    /// Snapshot for a related follow-up QP, retaining both dual blocks.
    public var warmStart: QuadraticWarmStart {
        .init(primal: point, rowDual: rowDual, variableDual: variableDual)
    }
}

public struct QuadraticIteration: Sendable, Hashable {
    public let iteration: Int
    public let objective: Double
    public let primalResidual: Double
    public let dualResidual: Double
}

public enum ConvexQuadraticSolver {
    public typealias Observer = (QuadraticIteration) -> Bool

    public static func solve(_ problem: QuadraticProblem, options: QuadraticOptions = .init(),
                             warmStart: QuadraticWarmStart? = nil,
                             observer: Observer? = nil) throws -> QuadraticResult {
        try validate(options); try problem.validate(convexityTolerance: options.convexityTolerance)
        let n = problem.linear.count, m = problem.rowBounds.count, p = m + n
        var combined = problem.constraints.dense()
        for column in 0..<n {
            var row = [Double](repeating: 0, count: n); row[column] = 1; combined.append(row)
        }
        let bounds = problem.rowBounds + problem.variableBounds
        var system = problem.quadratic
        for i in 0..<n { for j in 0..<n {
            var sum = 0.0
            for row in combined { sum += row[i] * row[j] }
            system[i][j] += options.rho * sum
        }}
        guard let factor = qpCholesky(system) else {
            return makeResult(problem, [Double](repeating: 0, count: n),
                              [Double](repeating: 0, count: p), 0, .numericalFailure,
                              .infinity, .infinity)
        }
        var point: [Double], scaledDual: [Double]
        if let warmStart {
            guard warmStart.primal.count == n, warmStart.rowDual.count == m,
                  warmStart.variableDual.count == n,
                  (warmStart.primal + warmStart.rowDual + warmStart.variableDual).allSatisfy(\.isFinite) else {
                throw NonlinearOptimizationError.invalidConfiguration("QP warm start dimensions or values are invalid")
            }
            point = warmStart.primal
            scaledDual = (warmStart.rowDual + warmStart.variableDual).map { $0 / options.rho }
        } else {
            point = [Double](repeating: 0, count: n)
            scaledDual = [Double](repeating: 0, count: p)
        }
        var product = qpMatvec(combined, point)
        var projected = qpProjected(product, scaledDual, bounds)
        var primalResidual = Double.infinity, dualResidual = Double.infinity
        for iteration in 1...options.maxIterations {
            var rhs = [Double](repeating: 0, count: n)
            for column in 0..<n {
                var sum = 0.0
                for row in 0..<p { sum += combined[row][column] * (projected[row] - scaledDual[row]) }
                rhs[column] = -problem.linear[column] + options.rho * sum
            }
            point = qpSolveCholesky(factor, rhs)
            guard point.allSatisfy(\.isFinite) else {
                return makeResult(problem, point, [Double](repeating: 0, count: p),
                                  iteration, .numericalFailure, .infinity, .infinity)
            }
            product = qpMatvec(combined, point)
            let oldProjected = projected
            projected = qpProjected(product, scaledDual, bounds)
            for index in 0..<p { scaledDual[index] += product[index] - projected[index] }
            primalResidual = qpInfinity(zip(product, projected).map(-))
            let change = zip(projected, oldProjected).map(-)
            dualResidual = options.rho * qpInfinity(qpTransposeMatvec(combined, change))
            let epsilonPrimal = options.absoluteTolerance
                + options.relativeTolerance * max(qpInfinity(product), qpInfinity(projected))
            let dual = scaledDual.map { options.rho * $0 }
            let qx = qpMatvec(problem.quadratic, point)
            let ctl = qpTransposeMatvec(combined, dual)
            let epsilonDual = options.absoluteTolerance
                + options.relativeTolerance * max(qpInfinity(qx), qpInfinity(ctl), qpInfinity(problem.linear))
            if observer?(.init(iteration: iteration, objective: problem.objective(at: point),
                               primalResidual: primalResidual, dualResidual: dualResidual)) == false {
                return makeResult(problem, point, dual, iteration, .cancelled,
                                  primalResidual, dualResidual)
            }
            if primalResidual <= epsilonPrimal, dualResidual <= epsilonDual {
                return makeResult(problem, point, dual, iteration, .converged,
                                  primalResidual, dualResidual)
            }
        }
        return makeResult(problem, point, scaledDual.map { options.rho * $0 },
                          options.maxIterations, .iterationLimit, primalResidual, dualResidual)
    }

    private static func validate(_ options: QuadraticOptions) throws {
        guard options.maxIterations > 0, options.rho.isFinite, options.rho > 0,
              options.absoluteTolerance.isFinite, options.absoluteTolerance > 0,
              options.relativeTolerance.isFinite, options.relativeTolerance > 0,
              options.convexityTolerance.isFinite, options.convexityTolerance >= 0 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid convex QP options")
        }
    }
}

private func makeResult(_ problem: QuadraticProblem, _ point: [Double], _ dual: [Double],
                        _ iterations: Int, _ termination: QuadraticTermination,
                        _ primalResidual: Double, _ dualResidual: Double) -> QuadraticResult {
    let matrix = problem.constraints.dense(), m = problem.rowBounds.count
    let activity = qpMatvec(matrix, point)
    var combined = matrix
    for column in point.indices { var row = [Double](repeating: 0, count: point.count); row[column] = 1; combined.append(row) }
    let qx = qpMatvec(problem.quadratic, point)
    var stationarity = [Double](repeating: 0, count: point.count)
    for index in point.indices { stationarity[index] = qx[index] + problem.linear[index] }
    let dualTerm = qpTransposeMatvec(combined, dual)
    return .init(point: point, objective: problem.objective(at: point), rowActivity: activity,
                 rowDual: Array(dual.prefix(m)), variableDual: Array(dual.dropFirst(m)),
                 iterations: iterations, termination: termination,
                 primalResidual: primalResidual, dualResidual: dualResidual,
                 stationarityNorm: qpInfinity(zip(stationarity, dualTerm).map(+)),
                 maximumRowViolation: qpMaxViolation(activity, problem.rowBounds),
                 maximumVariableViolation: qpMaxViolation(point, problem.variableBounds))
}

private func qpValidBound(_ bound: ParameterBound) -> Bool {
    (bound.lower?.isFinite ?? true) && (bound.upper?.isFinite ?? true)
        && (bound.lower ?? -.infinity) <= (bound.upper ?? .infinity)
}
private func qpProject(_ value: Double, _ bound: ParameterBound) -> Double {
    max(bound.lower ?? -.infinity, min(value, bound.upper ?? .infinity))
}
private func qpMaxViolation(_ values: [Double], _ bounds: [ParameterBound]) -> Double {
    var result = 0.0
    for index in values.indices {
        if let lower = bounds[index].lower { result = max(result, lower - values[index]) }
        if let upper = bounds[index].upper { result = max(result, values[index] - upper) }
    }
    return max(0, result)
}
private func qpProjected(_ values: [Double], _ dual: [Double],
                         _ bounds: [ParameterBound]) -> [Double] {
    var result = [Double](repeating: 0, count: values.count)
    for index in values.indices { result[index] = qpProject(values[index] + dual[index], bounds[index]) }
    return result
}
private func qpDot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
private func qpInfinity(_ x: [Double]) -> Double { x.map(abs).max() ?? 0 }
private func qpMatvec(_ a: [[Double]], _ x: [Double]) -> [Double] { a.map { qpDot($0, x) } }
private func qpTransposeMatvec(_ a: [[Double]], _ x: [Double]) -> [Double] {
    var result = [Double](repeating: 0, count: a.first?.count ?? 0)
    for (row, scale) in zip(a, x) { for index in result.indices { result[index] += row[index] * scale } }
    return result
}
private func qpCholesky(_ a: [[Double]]) -> [[Double]]? {
    let n = a.count; var lower = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
    for i in 0..<n { for j in 0...i {
        var product = 0.0
        if j > 0 { for k in 0..<j { product += lower[i][k] * lower[j][k] } }
        let value = a[i][j] - product
        if i == j { guard value.isFinite, value > 0 else { return nil }; lower[i][j] = sqrt(value) }
        else { lower[i][j] = value / lower[j][j] }
    }}
    return lower
}
private func qpSolveCholesky(_ lower: [[Double]], _ rhs: [Double]) -> [Double] {
    let n = rhs.count; var y = [Double](repeating: 0, count: n), x = y
    for i in 0..<n { var sum = 0.0; if i > 0 { for j in 0..<i { sum += lower[i][j] * y[j] } }; y[i] = (rhs[i] - sum) / lower[i][i] }
    for i in (0..<n).reversed() { var sum = 0.0; if i + 1 < n { for j in (i + 1)..<n { sum += lower[j][i] * x[j] } }; x[i] = (y[i] - sum) / lower[i][i] }
    return x
}
