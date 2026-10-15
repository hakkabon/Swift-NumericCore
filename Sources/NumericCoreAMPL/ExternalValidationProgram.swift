import NumericCore
import NumericCoreOptimization

/// Offline fixtures from independently maintained numerical reference corpora.
public enum ExternalValidationProgram {
    public static func run() throws -> [ValidationCase] {
        [try nistMisra1a(), try cutestHS71()]
    }

    private static func nistMisra1a() throws -> ValidationCase {
        let observations: [(Double, Double)] = [
            (10.07, 77.6), (14.73, 114.9), (17.94, 141.1), (23.93, 190.8),
            (29.61, 239.9), (35.18, 289.0), (40.02, 332.8), (44.82, 378.4),
            (50.76, 434.8), (55.05, 477.3), (61.01, 536.8), (66.40, 593.1),
            (75.47, 689.1), (81.78, 760.0),
        ]
        let residuals = observations.map { response, predictor in
            NonlinearExpression(nodes: [
                .parameter(0), .constant(1), .parameter(1), .constant(-predictor),
                .multiply(2, 3), .exp(4), .subtract(1, 5), .multiply(0, 6),
                .constant(response), .subtract(7, 8),
            ], output: 9)
        }
        let model = try NonlinearModel.leastSquares(
            parameterCount: 2, bounds: [.free, .free], residuals: residuals)
        let swift = try NonlinearModelSolver.leastSquares(
            model: model, initial: [250, 0.0005], backend: .swift)
        let rust = try NonlinearModelSolver.leastSquares(
            model: model, initial: [250, 0.0005], backend: .rust)
        let parameterTolerance = ValidationTolerance(absolute: 3e-3, relative: 2e-5)
        let rateTolerance = ValidationTolerance(absolute: 2e-8, relative: 2e-5)
        let rssTolerance = ValidationTolerance(absolute: 2e-5, relative: 2e-5)
        let swiftRSS = swift.residuals.reduce(0) { $0 + $1 * $1 }
        let rustRSS = rust.residuals.reduce(0) { $0 + $1 * $1 }
        return .init(id: "nist.strd.misra1a", family: "nonlinear-least-squares",
            tier: .standard, name: "NIST StRD Misra1a nonlinear regression", metrics: [
            .init(name: "Swift Misra1a b1", observed: swift.point[0],
                  reference: 2.3894212918e2, tolerance: parameterTolerance),
            .init(name: "Swift Misra1a b2", observed: swift.point[1],
                  reference: 5.5015643181e-4, tolerance: rateTolerance),
            .init(name: "Swift Misra1a RSS", observed: swiftRSS,
                  reference: 1.2455138894e-1, tolerance: rssTolerance),
            .init(name: "Rust Misra1a b1", observed: rust.point[0],
                  reference: 2.3894212918e2, tolerance: parameterTolerance),
            .init(name: "Rust Misra1a b2", observed: rust.point[1],
                  reference: 5.5015643181e-4, tolerance: rateTolerance),
            .init(name: "Rust Misra1a RSS", observed: rustRSS,
                  reference: 1.2455138894e-1, tolerance: rssTolerance),
        ], provenance: .init(
            collection: "NIST Statistical Reference Datasets", problem: "Misra1a",
            citation: "Misra, D., NIST (1978), Dental Research Monomolecular Adsorption Study",
            sourceURL: "https://www.itl.nist.gov/div898/strd/nls/data/LINKS/DATA/Misra1a.dat"))
    }

    private static func cutestHS71() throws -> ValidationCase {
        let objective = NonlinearExpression(nodes: [
            .parameter(0), .parameter(1), .parameter(2), .parameter(3),
            .add(0, 1), .add(4, 2), .multiply(0, 3), .multiply(6, 5), .add(7, 2),
        ], output: 8)
        let product = NonlinearExpression(nodes: [
            .parameter(0), .parameter(1), .parameter(2), .parameter(3),
            .multiply(0, 1), .multiply(4, 2), .multiply(5, 3),
        ], output: 6)
        let squares = NonlinearExpression(nodes: [
            .parameter(0), .pow(0, 2), .parameter(1), .pow(2, 2),
            .parameter(2), .pow(4, 2), .parameter(3), .pow(6, 2),
            .add(1, 3), .add(8, 5), .add(9, 7),
        ], output: 10)
        let model = try NonlinearModel.objective(parameterCount: 4,
            bounds: [ParameterBound(lower: 1, upper: 5), ParameterBound(lower: 1, upper: 5),
                     ParameterBound(lower: 1, upper: 5), ParameterBound(lower: 1, upper: 5)],
            expression: objective)
        let problem = try ConstrainedNonlinearProblem(model: model, constraints: [
            .init(expression: product, bound: .init(lower: 25)),
            .init(expression: squares, bound: .init(lower: 40, upper: 40)),
        ])
        let options = SQPOptions(maxIterations: 300, restoration: true)
        let swift = try NonlinearModelSolver.minimizeSQP(
            problem: problem, initial: [1, 5, 5, 1], backend: .swift, options: options)
        let rust = try NonlinearModelSolver.minimizeSQP(
            problem: problem, initial: [1, 5, 5, 1], backend: .rust, options: options)
        let reference = [1.0, 4.74299963, 3.82114998, 1.37940829]
        let tolerance = ValidationTolerance(absolute: 3e-4, relative: 3e-5)
        var metrics = zip(swift.point, reference).enumerated().map {
            ValidationMetric(name: "Swift HS71 x\($0.offset + 1)", observed: $0.element.0,
                             reference: $0.element.1, tolerance: tolerance)
        }
        metrics += zip(rust.point, reference).enumerated().map {
            ValidationMetric(name: "Rust HS71 x\($0.offset + 1)", observed: $0.element.0,
                             reference: $0.element.1, tolerance: tolerance)
        }
        metrics += [
            .init(name: "Swift HS71 objective", observed: swift.objective,
                  reference: 17.0140173, tolerance: tolerance),
            .init(name: "Rust HS71 objective", observed: rust.objective,
                  reference: 17.0140173, tolerance: tolerance),
            .init(name: "Swift HS71 feasibility", observed: swift.maximumViolation,
                  reference: 0, tolerance: .init(absolute: 2e-5, relative: 0)),
            .init(name: "Rust HS71 feasibility", observed: rust.maximumViolation,
                  reference: 0, tolerance: .init(absolute: 2e-5, relative: 0)),
        ]
        return .init(id: "cutest.hs71", family: "constrained-nonlinear", tier: .standard,
            name: "CUTEst HS71 constrained nonlinear program", metrics: metrics,
            provenance: .init(collection: "CUTEst SIF problem set", problem: "HS71",
                citation: "Hock and Schittkowski (1981), Test Examples for Nonlinear Programming Codes, problem 71",
                sourceURL: "https://github.com/ralna/SIF/blob/master/HS71.SIF"))
    }
}
