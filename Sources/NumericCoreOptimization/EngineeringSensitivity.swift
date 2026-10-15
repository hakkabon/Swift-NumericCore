import Foundation
import NumericCore
import NumericCoreSparse

/// A scalar engineering response whose total parameter derivative is sought.
public struct EngineeringResponseGradient: Sendable, Hashable {
    public let name: String
    public let stateGradient: [Double]
    public let directParameterGradient: [Double]

    public init(name: String, stateGradient: [Double],
                directParameterGradient: [Double]) {
        self.name = name
        self.stateGradient = stateGradient
        self.directParameterGradient = directParameterGradient
    }
}

public struct EngineeringResponseSensitivity: Sendable, Hashable {
    public let name: String
    /// Solution of `A.transpose * adjoint = stateGradient`.
    public let adjoint: [Double]
    /// Total response derivative with respect to every engineering parameter.
    public let parameterGradient: [Double]
    /// Independently contracted forward-mode gradient.
    public let forwardParameterGradient: [Double]
    public let maximumForwardAdjointMismatch: Double
    public let adjointResidualNorm: Double
}

public struct EngineeringSensitivityResult: Sendable, Hashable {
    /// One state-sensitivity vector per parameter: `dy/dp[j]`.
    public let stateSensitivities: [[Double]]
    public let responses: [EngineeringResponseSensitivity]
    public let operatingResidualNorm: Double
    public let maximumForwardResidualNorm: Double
    /// Coefficient in `d(ydot)/dp = derivativeSensitivityFactor * dy/dp`.
    public let derivativeSensitivityFactor: Double
}

extension EngineeringModel {
    /// Computes implicit forward and discrete-adjoint sensitivities at an
    /// operating point. For a steady system use the default factor zero. An
    /// implicit DAE step supplies its local `d(ydot)/dy` coefficient.
    public func sensitivities(
        time: Double, state: [Double], derivative: [Double],
        derivativeSensitivityFactor alpha: Double = 0,
        responses: [EngineeringResponseGradient]
    ) throws -> EngineeringSensitivityResult {
        guard alpha.isFinite, !parameters.isEmpty, !responses.isEmpty,
              responses.allSatisfy({ !$0.name.isEmpty
                  && $0.stateGradient.count == unknowns.count
                  && $0.directParameterGradient.count == parameters.count
                  && $0.stateGradient.allSatisfy(\.isFinite)
                  && $0.directParameterGradient.allSatisfy(\.isFinite) }),
              Set(responses.map(\.name)).count == responses.count else {
            throw engineeringSensitivityInvalid("invalid engineering sensitivity request")
        }
        let assembly = try assemble(time: time, state: state, derivative: derivative)
        let tangent = try engineeringEffectiveTangent(assembly, alpha: alpha)
        let factor = try SparseLUFactorization(matrix: tangent)
        var forward: [[Double]] = []
        var maximumForwardResidual = 0.0
        for parameter in parameters.indices {
            let column = engineeringColumn(assembly.parameterJacobian, parameter)
            let sensitivity = try factor.solve(column.map { -$0 })
            forward.append(sensitivity)
            let product = try tangent.multiplying(Vector(sensitivity)).storage
            maximumForwardResidual = max(maximumForwardResidual,
                engineeringNorm(zip(product, column).map(+)))
        }
        let transpose = try tangent.transposed()
        let transposeFactor = try SparseLUFactorization(matrix: transpose)
        let parameterTranspose = try assembly.parameterJacobian.transposed()
        let responseResults = try responses.map { response in
            let adjoint = try transposeFactor.solve(response.stateGradient)
            let transposeProduct = try transpose.multiplying(Vector(adjoint)).storage
            let adjointResidual = engineeringNorm(zip(transposeProduct, response.stateGradient).map(-))
            let implicit = try parameterTranspose.multiplying(Vector(adjoint)).storage
            let gradient = zip(response.directParameterGradient, implicit).map(-)
            let forwardGradient = parameters.indices.map { parameter in
                response.directParameterGradient[parameter]
                    + zip(response.stateGradient, forward[parameter]).reduce(0) { $0 + $1.0*$1.1 }
            }
            let mismatch = zip(gradient, forwardGradient).map { abs($0-$1) }.max() ?? 0
            return EngineeringResponseSensitivity(name: response.name, adjoint: adjoint,
                parameterGradient: gradient, forwardParameterGradient: forwardGradient,
                maximumForwardAdjointMismatch: mismatch,
                adjointResidualNorm: adjointResidual)
        }
        return .init(stateSensitivities: forward, responses: responseResults,
            operatingResidualNorm: engineeringNorm(assembly.residuals),
            maximumForwardResidualNorm: maximumForwardResidual,
            derivativeSensitivityFactor: alpha)
    }
}

private func engineeringEffectiveTangent(_ assembly: EngineeringAssembly,
                                         alpha: Double) throws -> SparseMatrix<Double> {
    var entries = engineeringEntries(assembly.jacobianState)
    if alpha != 0 {
        entries += engineeringEntries(assembly.jacobianDerivative).map {
            .init(row: $0.row, column: $0.column, value: alpha*$0.value)
        }
    }
    return try SparseMatrix(rows: assembly.jacobianState.rows,
                            cols: assembly.jacobianState.cols, entries: entries)
}

private func engineeringEntries(_ matrix: SparseMatrix<Double>) -> [SparseEntry<Double>] {
    (0..<matrix.rows).flatMap { row in
        (matrix.csrRowPointers[row]..<matrix.csrRowPointers[row+1]).map { index in
            .init(row: row, column: matrix.csrColumnIndices[index],
                  value: matrix.csrValues[index])
        }
    }
}

private func engineeringColumn(_ matrix: SparseMatrix<Double>, _ column: Int) -> [Double] {
    var result = [Double](repeating: 0, count: matrix.rows)
    for row in 0..<matrix.rows {
        for index in matrix.csrRowPointers[row]..<matrix.csrRowPointers[row+1]
            where matrix.csrColumnIndices[index] == column {
            result[row] = matrix.csrValues[index]
        }
    }
    return result
}

private func engineeringNorm(_ values: [Double]) -> Double {
    sqrt(values.reduce(0) { $0 + $1*$1 })
}

private func engineeringSensitivityInvalid(_ message: String) -> NonlinearOptimizationError {
    .invalidConfiguration(message)
}
