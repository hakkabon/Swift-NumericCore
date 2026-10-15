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

/// Result of an equality-constrained active-set refinement of a converged QP point.
public struct QuadraticPolishResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let attempted: Bool
    public let accepted: Bool
    public let activeConstraints: Int
    public let objectiveImprovement: Double
    public let maximumRowViolation: Double
    public let maximumVariableViolation: Double
}

public enum QuadraticPolisher {
    public static func polish(_ problem: QuadraticProblem, result: QuadraticResult,
                              activeTolerance: Double = 1e-6) throws -> QuadraticPolishResult {
        try problem.validate()
        guard activeTolerance.isFinite, activeTolerance > 0 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid QP polish tolerance")
        }
        guard result.termination == .converged, result.point.count == problem.linear.count else {
            return qpPolishResult(problem, result.point, result.objective, false, false, 0, result.objective)
        }
        let matrix = problem.constraints.dense(), activity = qpMatvec(matrix, result.point)
        var active: [[Double]] = [], targets: [Double] = []
        for row in matrix.indices {
            if let lower = problem.rowBounds[row].lower,
               abs(activity[row] - lower) <= activeTolerance {
                active.append(matrix[row]); targets.append(lower)
            } else if let upper = problem.rowBounds[row].upper,
                      abs(activity[row] - upper) <= activeTolerance {
                active.append(matrix[row]); targets.append(upper)
            }
        }
        for column in result.point.indices {
            var target: Double?
            if let lower = problem.variableBounds[column].lower,
               abs(result.point[column] - lower) <= activeTolerance { target = lower }
            else if let upper = problem.variableBounds[column].upper,
                    abs(result.point[column] - upper) <= activeTolerance { target = upper }
            if let target {
                var row = [Double](repeating: 0, count: result.point.count); row[column] = 1
                active.append(row); targets.append(target)
            }
        }
        guard !active.isEmpty, let candidate = qpSolveKKT(problem, active, targets) else {
            return qpPolishResult(problem, result.point, result.objective, true, false,
                                  active.count, result.objective)
        }
        let rowViolation = qpMaxViolation(qpMatvec(matrix, candidate), problem.rowBounds)
        let variableViolation = qpMaxViolation(candidate, problem.variableBounds)
        let objective = problem.objective(at: candidate)
        let accepted = candidate.allSatisfy(\.isFinite)
            && rowViolation <= activeTolerance && variableViolation <= activeTolerance
            && objective <= result.objective + activeTolerance
        return qpPolishResult(problem, accepted ? candidate : result.point,
                              accepted ? objective : result.objective, true, accepted,
                              active.count, result.objective)
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
        var rho = options.rho
        guard var factor = qpFactorSystem(problem, combined, rho) else {
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
            scaledDual = (warmStart.rowDual + warmStart.variableDual).map { $0 / rho }
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
                rhs[column] = -problem.linear[column] + rho * sum
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
            dualResidual = rho * qpInfinity(qpTransposeMatvec(combined, change))
            let epsilonPrimal = options.absoluteTolerance
                + options.relativeTolerance * max(qpInfinity(product), qpInfinity(projected))
            let dual = scaledDual.map { rho * $0 }
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
            if iteration.isMultiple(of: 25) {
                let nextRho: Double
                if primalResidual > 10 * dualResidual { nextRho = min(rho * 2, 1e8) }
                else if dualResidual > 10 * primalResidual { nextRho = max(rho * 0.5, 1e-8) }
                else { nextRho = rho }
                if nextRho != rho {
                    let scale = rho / nextRho
                    scaledDual = scaledDual.map { $0 * scale }; rho = nextRho
                    guard let nextFactor = qpFactorSystem(problem, combined, rho) else {
                        return makeResult(problem, point, [Double](repeating: 0, count: p),
                                          iteration, .numericalFailure, .infinity, .infinity)
                    }
                    factor = nextFactor
                }
            }
        }
        return makeResult(problem, point, scaledDual.map { rho * $0 },
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

private func qpFactorSystem(_ problem: QuadraticProblem, _ combined: [[Double]], _ rho: Double)
    -> [[Double]]? {
    var system = problem.quadratic
    for i in system.indices { for j in system.indices {
        var sum = 0.0
        for row in combined { sum += row[i] * row[j] }
        system[i][j] += rho * sum
    }}
    return qpCholesky(system)
}

private func qpPolishResult(_ problem: QuadraticProblem, _ point: [Double], _ objective: Double,
                            _ attempted: Bool, _ accepted: Bool, _ active: Int,
                            _ originalObjective: Double) -> QuadraticPolishResult {
    let rowViolation = point.count == problem.linear.count
        ? qpMaxViolation(qpMatvec(problem.constraints.dense(), point), problem.rowBounds) : .infinity
    let variableViolation = point.count == problem.linear.count
        ? qpMaxViolation(point, problem.variableBounds) : .infinity
    return .init(point: point, objective: objective, attempted: attempted, accepted: accepted,
                 activeConstraints: active, objectiveImprovement: originalObjective - objective,
                 maximumRowViolation: rowViolation, maximumVariableViolation: variableViolation)
}

private func qpSolveKKT(_ problem: QuadraticProblem, _ active: [[Double]], _ targets: [Double])
    -> [Double]? {
    let n = problem.linear.count, size = n + active.count
    var system = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
    var rhs = [Double](repeating: 0, count: size)
    for row in 0..<n {
        rhs[row] = -problem.linear[row]
        for column in 0..<n { system[row][column] = problem.quadratic[row][column] }
    }
    for row in active.indices {
        rhs[n + row] = targets[row]
        for column in 0..<n {
            system[column][n + row] = active[row][column]
            system[n + row][column] = active[row][column]
        }
    }
    guard let solution = qpSolvePivoted(system, rhs) else { return nil }
    return Array(solution.prefix(n))
}

private func qpSolvePivoted(_ input: [[Double]], _ inputRHS: [Double]) -> [Double]? {
    var a = input, b = inputRHS; let n = b.count
    for column in 0..<n {
        var pivot = column
        if column + 1 < n {
            for row in (column + 1)..<n where abs(a[row][column]) > abs(a[pivot][column]) { pivot = row }
        }
        guard abs(a[pivot][column]) > 1e-12 else { return nil }
        if pivot != column { a.swapAt(pivot, column); b.swapAt(pivot, column) }
        if column + 1 < n {
            for row in (column + 1)..<n {
                let scale = a[row][column] / a[column][column]
                for index in column..<n { a[row][index] -= scale * a[column][index] }
                b[row] -= scale * b[column]
            }
        }
    }
    var x = [Double](repeating: 0, count: n)
    for row in (0..<n).reversed() {
        var value = b[row]
        if row + 1 < n { for column in (row + 1)..<n { value -= a[row][column] * x[column] } }
        x[row] = value / a[row][row]
    }
    return x.allSatisfy(\.isFinite) ? x : nil
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
