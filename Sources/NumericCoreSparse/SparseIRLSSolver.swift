import Foundation
import NumericCore

/// Canonical-link generalized linear models supported by sparse IRLS.
public enum SparseGLMFamily: Sendable, Hashable {
    case binomialLogit
    case poissonLog
}

/// Outcome of a penalized sparse iteratively reweighted least-squares fit.
public struct SparseIRLSResult: Sendable, Hashable {
    public let coefficients: [Double]
    public let iterations: Int
    public let converged: Bool
    public let deviance: Double
    public let lastLeastSquaresResult: SparseStatisticalLeastSquaresResult
}

/// Model-facing sparse IRLS built on the same penalized weighted
/// least-squares primitive used by dense/sparse parity tests.
///
/// This owns only numerical iteration. Basis construction, smoothing
/// parameter selection, effective degrees of freedom, and inference remain
/// responsibilities of the statistical package (for example DataLens).
public enum SparseIRLSSolver {
    public static func fit(
        design: SparseMatrix<Double>,
        response: [Double],
        penalty: SparseMatrix<Double>,
        penaltyWeight: Double,
        family: SparseGLMFamily,
        initialCoefficients: [Double]? = nil,
        maxIterations: Int = 50,
        coefficientTolerance: Double = 1e-8,
        leastSquaresMaxIterations: Int = 1_000,
        leastSquaresTolerance: Double = 1e-8
    ) throws -> SparseIRLSResult {
        guard response.count == design.rows else {
            throw NCError.dimensionMismatch("IRLS response must have \(design.rows) entries")
        }
        guard penalty.cols == design.cols else {
            throw NCError.dimensionMismatch("IRLS penalty must have \(design.cols) columns")
        }
        guard maxIterations > 0,
              coefficientTolerance.isFinite, coefficientTolerance > 0,
              response.allSatisfy(\.isFinite) else {
            throw NCError.unsupportedOperation("IRLS requires finite data and positive convergence settings")
        }
        try validate(response: response, family: family)

        var coefficients = initialCoefficients ?? [Double](repeating: 0, count: design.cols)
        guard coefficients.count == design.cols, coefficients.allSatisfy(\.isFinite) else {
            throw NCError.dimensionMismatch("IRLS initial coefficients must have \(design.cols) finite entries")
        }

        var last: SparseStatisticalLeastSquaresResult?
        for iteration in 1...maxIterations {
            let eta = try design.multiplying(Vector(coefficients)).storage
            let working = workingData(response: response, eta: eta, family: family)
            let solve = try SparseStatisticalSolver.penalizedWeightedLeastSquares(
                design: design,
                response: working.response,
                weights: working.weights,
                penalty: penalty,
                penaltyWeight: penaltyWeight,
                maxIterations: leastSquaresMaxIterations,
                tolerance: leastSquaresTolerance
            )
            last = solve
            guard solve.converged else {
                return SparseIRLSResult(
                    coefficients: solve.coefficients, iterations: iteration,
                    converged: false,
                    deviance: deviance(response: response, eta: eta, family: family),
                    lastLeastSquaresResult: solve
                )
            }

            let delta = zip(solve.coefficients, coefficients)
                .map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
            let scale = max(1, solve.coefficients.map { $0 * $0 }.reduce(0, +).squareRoot())
            coefficients = solve.coefficients
            if delta / scale <= coefficientTolerance {
                let finalEta = try design.multiplying(Vector(coefficients)).storage
                return SparseIRLSResult(
                    coefficients: coefficients, iterations: iteration, converged: true,
                    deviance: deviance(response: response, eta: finalEta, family: family),
                    lastLeastSquaresResult: solve
                )
            }
        }

        let final = last!
        let finalEta = try design.multiplying(Vector(coefficients)).storage
        return SparseIRLSResult(
            coefficients: coefficients, iterations: maxIterations, converged: false,
            deviance: deviance(response: response, eta: finalEta, family: family),
            lastLeastSquaresResult: final
        )
    }

    private static func validate(response: [Double], family: SparseGLMFamily) throws {
        let valid: Bool
        switch family {
        case .binomialLogit: valid = response.allSatisfy { (0...1).contains($0) }
        case .poissonLog: valid = response.allSatisfy { $0 >= 0 }
        }
        guard valid else {
            throw NCError.unsupportedOperation("response is outside the domain of the selected GLM family")
        }
    }

    private static func workingData(
        response: [Double], eta: [Double], family: SparseGLMFamily
    ) -> (response: [Double], weights: [Double]) {
        switch family {
        case .binomialLogit:
            let means = eta.map { min(max(1 / (1 + exp(-min(max($0, -30), 30))), 1e-12), 1 - 1e-12) }
            let weights = means.map { max($0 * (1 - $0), 1e-12) }
            return (zip(zip(eta, response), zip(means, weights)).map {
                $0.0.0 + ($0.0.1 - $0.1.0) / $0.1.1
            }, weights)
        case .poissonLog:
            let means = eta.map { exp(min(max($0, -30), 30)) }
            return (zip(zip(eta, response), means).map {
                $0.0.0 + ($0.0.1 - $0.1) / $0.1
            }, means)
        }
    }

    private static func deviance(
        response: [Double], eta: [Double], family: SparseGLMFamily
    ) -> Double {
        switch family {
        case .binomialLogit:
            return 2 * zip(response, eta).map { observed, linear in
                let mean = min(max(1 / (1 + exp(-min(max(linear, -30), 30))), 1e-12), 1 - 1e-12)
                let positive = observed == 0 ? 0 : observed * log(observed / mean)
                let negative = observed == 1 ? 0 : (1 - observed) * log((1 - observed) / (1 - mean))
                return positive + negative
            }.reduce(0, +)
        case .poissonLog:
            return 2 * zip(response, eta).map { observed, linear in
                let mean = exp(min(max(linear, -30), 30))
                return (observed == 0 ? 0 : observed * log(observed / mean)) - (observed - mean)
            }.reduce(0, +)
        }
    }
}
