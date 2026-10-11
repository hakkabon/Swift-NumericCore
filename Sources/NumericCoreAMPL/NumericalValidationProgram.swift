import NumericCore
import NumericCoreOptimization

/// Deterministic, hand-checkable validation program spanning the production
/// LP, QP, MILP, and nonlinear paths, including Swift/Rust nonlinear parity.
public enum NumericCoreValidationProgram {
    public static func run() throws -> ValidationReport {
        let tolerance = ValidationTolerance(absolute: 1e-7, relative: 1e-7)

        let lpSource = """
        var x >= 0;
        var y >= 0, <= 10;
        maximize value: 3 x + 2 y;
        subject to capacity: x + y <= 4;
        subject to xlimit: x <= 3;
        """
        let compiledLP = try AMPLParser.parse(lpSource).compile()
        let lp = try compiledLP.solve(configuration: .simplex(.init(scaling: false)))
        let scaledLP = try compiledLP.solve(configuration: .simplex(.init(scaling: true)))
        let lpCase = ValidationCase(name: "LP reference and scaling invariance", metrics: [
            .init(name: "LP objective", observed: lp.objectiveValue,
                  reference: 11, tolerance: tolerance),
            .init(name: "scaled LP objective", observed: scaledLP.objectiveValue,
                  reference: lp.objectiveValue, tolerance: tolerance),
            .init(name: "LP row violation", observed: lp.diagnostics.maximumRowViolation,
                  reference: 0, tolerance: tolerance),
        ])

        let qpProblem = QuadraticProblem(
            quadratic: [[2]], linear: [-4], constraints: try .empty(columns: 1),
            rowBounds: [], variableBounds: [.init(lower: 0, upper: 1)])
        let qp = try ConvexQuadraticSolver.solve(
            qpProblem, options: .init(maxIterations: 2_000, rho: 1e-8))
        let qpTolerance = ValidationTolerance(absolute: 2e-6, relative: 1e-7)
        let qpCase = ValidationCase(name: "convex QP KKT reference", metrics: [
            .init(name: "QP point", observed: qp.point[0], reference: 1,
                  tolerance: qpTolerance),
            .init(name: "QP bound violation", observed: qp.maximumVariableViolation,
                  reference: 0, tolerance: qpTolerance),
            .init(name: "QP stationarity", observed: qp.stationarityNorm, reference: 0,
                  tolerance: .init(absolute: 1e-5, relative: 0)),
        ])

        let milpSource = """
        var x >= 0, <= 1 integer;
        var y >= 0, <= 1 integer;
        maximize value: 2 x + y;
        subject to capacity: x + y <= 1.4;
        """
        let milp = try AMPLParser.parse(milpSource).compile().solve(
            configuration: .branchAndBound())
        let milpCase = ValidationCase(name: "MILP enumerated optimum", metrics: [
            .init(name: "MILP objective", observed: milp.objectiveValue,
                  reference: 2, tolerance: tolerance),
            .init(name: "MILP integrality",
                  observed: milp.diagnostics.maximumIntegralityViolation,
                  reference: 0, tolerance: tolerance),
            .init(name: "MILP certified gap", observed: milp.searchReport?.absoluteGap ?? .infinity,
                  reference: 0, tolerance: tolerance),
        ])

        let expression = NonlinearExpression(nodes: [
            .parameter(0), .constant(2), .subtract(0, 1), .pow(2, 2),
            .parameter(1), .constant(-1), .subtract(4, 5), .pow(6, 2), .add(3, 7),
        ], output: 8)
        let model = try NonlinearModel.objective(
            parameterCount: 2, bounds: [.free, .free], expression: expression)
        let swift = try NonlinearModelSolver.minimize(
            model: model, initial: [8, -8], backend: .swift)
        let rust = try NonlinearModelSolver.minimize(
            model: model, initial: [8, -8], backend: .rust)
        let nonlinearCase = ValidationCase(name: "nonlinear Swift/Rust conformance", metrics: [
            .init(name: "Swift nonlinear x", observed: swift.point[0],
                  reference: 2, tolerance: tolerance),
            .init(name: "Swift nonlinear y", observed: swift.point[1],
                  reference: -1, tolerance: tolerance),
            .init(name: "Rust nonlinear x", observed: rust.point[0],
                  reference: swift.point[0], tolerance: tolerance),
            .init(name: "Rust nonlinear y", observed: rust.point[1],
                  reference: swift.point[1], tolerance: tolerance),
            .init(name: "Rust nonlinear objective", observed: rust.objective,
                  reference: swift.objective, tolerance: tolerance),
        ])

        return ValidationReport(cases: [lpCase, qpCase, milpCase, nonlinearCase])
    }
}
