import Foundation

public enum NonlinearActiveSide: Sendable, Hashable { case equality, lower, upper }

public struct NonlinearActiveConstraint: Sendable, Hashable {
    public let constraint: Int?
    public let variable: Int?
    public let side: NonlinearActiveSide
}

public struct NonlinearScalingOptions: Sendable, Hashable {
    public var activeTolerance: Double
    public var minimumFactor: Double
    public var maximumFactor: Double
    public var regularization: Double
    public var variableFactors: [Double]
    public init(activeTolerance: Double = 1e-6, minimumFactor: Double = 1e-8,
                maximumFactor: Double = 1e8, regularization: Double = 1e-10,
                variableFactors: [Double] = []) {
        self.activeTolerance = activeTolerance; self.minimumFactor = minimumFactor
        self.maximumFactor = maximumFactor; self.regularization = regularization
        self.variableFactors = variableFactors
    }
}

public struct NonlinearScalingReport: Sendable, Hashable {
    public let variableFactors: [Double]
    public let constraintFactors: [Double]
    public let activeSet: [NonlinearActiveConstraint]
    public let unscaledJacobianNormRange: ParameterBound
    public let scaledJacobianNormRange: ParameterBound
    public let pivotRatio: Double
}

public struct NonlinearSensitivityRequest: Sendable, Hashable {
    public var objectiveGradientPerturbation: [Double]
    public var constraintBoundPerturbation: [Double]
    public var variableBoundPerturbation: [Double]
    public init(objectiveGradientPerturbation: [Double],
                constraintBoundPerturbation: [Double],
                variableBoundPerturbation: [Double]) {
        self.objectiveGradientPerturbation = objectiveGradientPerturbation
        self.constraintBoundPerturbation = constraintBoundPerturbation
        self.variableBoundPerturbation = variableBoundPerturbation
    }
}

public struct NonlinearSensitivityResult: Sendable, Hashable {
    public let pointDerivative: [Double]
    public let constraintMultiplierDerivative: [ConstraintMultiplier]
    public let variableLowerMultiplierDerivative: [Double]
    public let variableUpperMultiplierDerivative: [Double]
    public let residualNorm: Double
    public let scaling: NonlinearScalingReport
}

public enum NonlinearSensitivityAnalyzer {
    public static func analyze(problem: ConstrainedNonlinearProblem,
                               result: ConstrainedResult,
                               request: NonlinearSensitivityRequest,
                               options: NonlinearScalingOptions = .init()) throws
        -> NonlinearSensitivityResult {
        try analyze(problem: problem, point: result.point, multipliers: result.multipliers,
                    request: request, options: options)
    }

    public static func analyze(problem: ConstrainedNonlinearProblem, point: [Double],
                               multipliers: [ConstraintMultiplier],
                               request: NonlinearSensitivityRequest,
                               options: NonlinearScalingOptions = .init()) throws
        -> NonlinearSensitivityResult {
        try problem.validate()
        let n = problem.model.parameterCount, m = problem.constraints.count
        guard point.count == n, multipliers.count == m,
              request.objectiveGradientPerturbation.count == n,
              request.constraintBoundPerturbation.count == m,
              request.variableBoundPerturbation.count == n,
              (point + request.objectiveGradientPerturbation
                + request.constraintBoundPerturbation
                + request.variableBoundPerturbation).allSatisfy(\.isFinite),
              options.activeTolerance.isFinite, options.activeTolerance > 0,
              options.minimumFactor.isFinite, options.minimumFactor > 0,
              options.maximumFactor.isFinite, options.maximumFactor >= options.minimumFactor,
              options.regularization.isFinite, options.regularization >= 0,
              options.variableFactors.isEmpty || options.variableFactors.count == n,
              options.variableFactors.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "invalid nonlinear scaling or sensitivity dimensions")
        }
        let values = try problem.evaluateConstraints(at: point)
        let variableFactors = options.variableFactors.isEmpty
            ? automaticVariableFactors(problem.model.bounds, point, options) : options.variableFactors
        var rows: [[Double]] = [], rhsBounds: [Double] = [], activeSet: [NonlinearActiveConstraint] = []
        for index in 0..<m {
            if let side = activeSide(problem.constraints[index].bound, values[index].value,
                                     options.activeTolerance) {
                rows.append(values[index].gradient)
                rhsBounds.append(request.constraintBoundPerturbation[index])
                activeSet.append(.init(constraint: index, variable: nil, side: side))
            }
        }
        for index in 0..<n {
            if let side = activeSide(problem.model.bounds[index], point[index], options.activeTolerance) {
                var row = [Double](repeating: 0, count: n); row[index] = 1
                rows.append(row); rhsBounds.append(request.variableBoundPerturbation[index])
                activeSet.append(.init(constraint: nil, variable: index, side: side))
            }
        }
        let weights = multipliers.indices.map { index in
            let multiplier = multipliers[index], bound = problem.constraints[index].bound
            return if let lower = bound.lower, let upper = bound.upper,
                      abs(upper - lower) <= options.activeTolerance {
                multiplier.equality
            } else { multiplier.upper - multiplier.lower }
        }
        var hessian = try problem.lagrangianHessian(
            parameters: point, constraintWeights: weights)
        for index in 0..<n { hessian[index][index] += options.regularization }
        let unscaledNorms = rows.map(rowNorm)
        let rowFactors = rows.map { row in
            let norm = rowNorm(zip(row, variableFactors).map(*))
            return min(options.maximumFactor, max(options.minimumFactor, 1 / max(1e-300, norm)))
        }
        let size = n + rows.count
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)
        var rhs = [Double](repeating: 0, count: size)
        for i in 0..<n {
            rhs[i] = -variableFactors[i] * request.objectiveGradientPerturbation[i]
            for j in 0..<n { matrix[i][j] = variableFactors[i] * hessian[i][j] * variableFactors[j] }
        }
        for row in rows.indices {
            rhs[n + row] = rowFactors[row] * rhsBounds[row]
            for column in 0..<n {
                let value = rowFactors[row] * rows[row][column] * variableFactors[column]
                matrix[column][n + row] = value; matrix[n + row][column] = value
            }
        }
        guard let solved = solveSensitivitySystem(matrix, rhs) else {
            throw NonlinearOptimizationError.invalidEvaluation("active nonlinear KKT system is singular")
        }
        let pointDerivative = zip(solved.prefix(n), variableFactors).map(*)
        let activeDual = rows.indices.map { rowFactors[$0] * solved[n + $0] }
        var constraintDerivative = [ConstraintMultiplier](repeating: .init(), count: m)
        var lowerDerivative = [Double](repeating: 0, count: n)
        var upperDerivative = lowerDerivative
        for (index, active) in activeSet.enumerated() {
            let dual = activeDual[index]
            if let constraint = active.constraint {
                switch active.side {
                case .equality: constraintDerivative[constraint].equality = dual
                case .lower: constraintDerivative[constraint].lower = -dual
                case .upper: constraintDerivative[constraint].upper = dual
                }
            } else if let variable = active.variable {
                if active.side == .lower { lowerDerivative[variable] = -dual }
                else { upperDerivative[variable] = dual }
            }
        }
        let residual = zip(matvec(matrix, solved), rhs).map { abs($0 - $1) }.max() ?? 0
        let scaledNorms = rows.indices.map { rowNorm(zip(rows[$0], variableFactors).map(*)) * rowFactors[$0] }
        return .init(pointDerivative: pointDerivative,
                     constraintMultiplierDerivative: constraintDerivative,
                     variableLowerMultiplierDerivative: lowerDerivative,
                     variableUpperMultiplierDerivative: upperDerivative,
                     residualNorm: residual,
                     scaling: .init(variableFactors: variableFactors,
                        constraintFactors: rowFactors, activeSet: activeSet,
                        unscaledJacobianNormRange: range(unscaledNorms),
                        scaledJacobianNormRange: range(scaledNorms),
                        pivotRatio: pivotRatio(matrix)))
    }
}

private func activeSide(_ bound: ParameterBound, _ value: Double, _ tolerance: Double)
    -> NonlinearActiveSide? {
    if let lower = bound.lower, let upper = bound.upper, abs(upper - lower) <= tolerance {
        return .equality
    }
    if let lower = bound.lower, abs(value - lower) <= tolerance { return .lower }
    if let upper = bound.upper, abs(value - upper) <= tolerance { return .upper }
    return nil
}

private func automaticVariableFactors(_ bounds: [ParameterBound], _ point: [Double],
                                      _ options: NonlinearScalingOptions) -> [Double] {
    point.indices.map { index in
        let width = ifFiniteWidth(bounds[index])
        return min(options.maximumFactor,
                   max(options.minimumFactor, max(1, abs(point[index]), width)))
    }
}

private func ifFiniteWidth(_ bound: ParameterBound) -> Double {
    guard let lower = bound.lower, let upper = bound.upper else { return 0 }
    return upper - lower
}
private func rowNorm(_ row: [Double]) -> Double { sqrt(row.reduce(0) { $0 + $1 * $1 }) }
private func range(_ values: [Double]) -> ParameterBound {
    .init(lower: values.min() ?? 0, upper: values.max() ?? 0)
}
private func matvec(_ matrix: [[Double]], _ point: [Double]) -> [Double] {
    matrix.map { zip($0, point).reduce(0) { $0 + $1.0 * $1.1 } }
}
private func pivotRatio(_ input: [[Double]]) -> Double {
    var matrix = input, minimum = Double.infinity, maximum = 0.0
    for column in matrix.indices {
        var pivot = column
        for row in column..<matrix.count where abs(matrix[row][column]) > abs(matrix[pivot][column]) {
            pivot = row
        }
        let value = abs(matrix[pivot][column]); guard value > 1e-14 else { return .infinity }
        minimum = min(minimum, value); maximum = max(maximum, value); matrix.swapAt(column, pivot)
        if column + 1 < matrix.count { for row in (column + 1)..<matrix.count {
            let factor = matrix[row][column] / matrix[column][column]
            for index in column..<matrix.count { matrix[row][index] -= factor * matrix[column][index] }
        }}
    }
    return maximum / minimum
}
private func solveSensitivitySystem(_ input: [[Double]], _ inputRHS: [Double]) -> [Double]? {
    var matrix = input, rhs = inputRHS; let n = rhs.count
    for column in 0..<n {
        var pivot = column
        for row in column..<n where abs(matrix[row][column]) > abs(matrix[pivot][column]) { pivot = row }
        guard abs(matrix[pivot][column]) > 1e-14 else { return nil }
        matrix.swapAt(column, pivot); rhs.swapAt(column, pivot)
        if column + 1 < n { for row in (column + 1)..<n {
            let factor = matrix[row][column] / matrix[column][column]
            for index in column..<n { matrix[row][index] -= factor * matrix[column][index] }
            rhs[row] -= factor * rhs[column]
        }}
    }
    var result = [Double](repeating: 0, count: n)
    for row in (0..<n).reversed() {
        var value = rhs[row]
        if row + 1 < n { for column in (row + 1)..<n { value -= matrix[row][column] * result[column] } }
        result[row] = value / matrix[row][row]
    }
    return result.allSatisfy(\.isFinite) ? result : nil
}
