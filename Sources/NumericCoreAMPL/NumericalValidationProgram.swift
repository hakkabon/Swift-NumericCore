import Foundation
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
        let lpCase = ValidationCase(id: "internal.lp.reference", family: "linear-programming",
                                    name: "LP reference and scaling invariance", metrics: [
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
        let qpCase = ValidationCase(id: "internal.qp.kkt", family: "quadratic-programming",
                                    name: "convex QP KKT reference", metrics: [
            .init(name: "QP point", observed: qp.point[0], reference: 1,
                  tolerance: qpTolerance),
            .init(name: "QP bound violation", observed: qp.maximumVariableViolation,
                  reference: 0, tolerance: qpTolerance),
            .init(name: "QP stationarity", observed: qp.stationarityNorm, reference: 0,
                  tolerance: .init(absolute: 1e-5, relative: 0)),
        ])
        let qpCertificate = try OptimizationCertifier.certifyConvexQP(
            problem: qpProblem, result: qp)
        let certificateCase = ValidationCase(id: "internal.certificate.qp-kkt",
            family: "optimization-certification", tier: .standard,
            name: "independent convex QP certificate", metrics: [
                .init(name: "QP certificate verified", observed: qpCertificate.verified ? 1 : 0,
                      reference: 1, tolerance: .init(absolute: 0, relative: 0)),
                .init(name: "QP optimality claim",
                      observed: qpCertificate.claim == .optimality ? 1 : 0,
                      reference: 1, tolerance: .init(absolute: 0, relative: 0)),
                .init(name: "QP certificate failures",
                      observed: Double(qpCertificate.metrics.filter { !$0.passed }.count),
                      reference: 0, tolerance: .init(absolute: 0, relative: 0)),
            ])

        let milpSource = """
        var x >= 0, <= 1 integer;
        var y >= 0, <= 1 integer;
        maximize value: 2 x + y;
        subject to capacity: x + y <= 1.4;
        """
        let milp = try AMPLParser.parse(milpSource).compile().solve(
            configuration: .branchAndBound())
        let milpCase = ValidationCase(id: "internal.milp.enumerated",
                                      family: "mixed-integer-programming",
                                      name: "MILP enumerated optimum", metrics: [
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
        let nonlinearCase = ValidationCase(id: "internal.nlp.conformance",
                                           family: "nonlinear-optimization",
                                           name: "nonlinear Swift/Rust conformance", metrics: [
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

        let sparseProblem = try SparseLinearProblem(
            objective: [2, 1], rows: 2, columns: 2,
            rowPointers: [0, 2, 3], columnIndices: [0, 1, 1], values: [1, 1, 1],
            rowBounds: [.init(lower: 3, upper: 3), .init(upper: 10)],
            variableBounds: [.init(lower: 1, upper: 1), .init(lower: 0, upper: 10)])
        let presolved = try LinearModelPresolver.presolve(sparseProblem)
        let restored = try presolved.restorePoint([])
        let presolveCase = ValidationCase(id: "internal.presolve.postsolve",
            family: "model-transformation", tier: .standard,
            name: "presolve and postsolve equivalence", metrics: [
            .init(name: "restored x", observed: restored[0], reference: 1,
                  tolerance: tolerance),
            .init(name: "restored y", observed: restored[1], reference: 2,
                  tolerance: tolerance),
            .init(name: "restored objective", observed: presolved.restoreObjective(0),
                  reference: 4, tolerance: tolerance),
            .init(name: "fixed variables", observed: Double(presolved.report.fixedVariables),
                  reference: 2, tolerance: .init(absolute: 0, relative: 0)),
        ])

        let workspaceProblem = try SparseLinearProblem(
            objective: [0, 0, 0], rows: 3, columns: 3,
            rowPointers: [0, 2, 4, 6], columnIndices: [0, 2, 0, 1, 1, 2],
            values: [1e-8, 2, -3, 4e8, 5, -6],
            rowBounds: [.free, .free, .free], variableBounds: [.free, .free, .free])
        let workspace = try SparseLinearWorkspace(problem: workspaceProblem)
        let activity = try workspace.rowActivity([2, -1, 3])
        let transpose = try workspace.transposeProduct([1, -2, 0.5])
        let sparseCase = ValidationCase(id: "internal.sparse.mixed-scale",
            family: "sparse-linear-algebra", tier: .standard,
            name: "sparse operator scale coverage", metrics: [
            .init(name: "scaled row 0", observed: activity[0], reference: 6.00000002,
                  tolerance: tolerance),
            .init(name: "scaled row 1", observed: activity[1], reference: -400000006,
                  tolerance: tolerance),
            .init(name: "transpose column 0", observed: transpose[0],
                  reference: 6.00000001, tolerance: tolerance),
            .init(name: "transpose column 2", observed: transpose[2], reference: -1,
                  tolerance: tolerance),
        ])

        let kktProblem = SparseKKTProblem(
            hessian: .init(dimension: 2, rowPointers: [0, 1, 2],
                           columnIndices: [0, 1], values: [2, 2]),
            jacobian: .init(rows: 1, columns: 2, rowPointers: [0, 2],
                            columnIndices: [0, 1], values: [1, 1]),
            primalRightHandSide: [-2, -4], constraintRightHandSide: [-1])
        let kktWorkspace = try SparseKKTWorkspace(problem: kktProblem)
        _ = try kktWorkspace.solve(kktProblem)
        let updatedKKT = SparseKKTProblem(
            hessian: .init(dimension: 2, rowPointers: [0, 1, 2],
                           columnIndices: [0, 1], values: [4, 3]),
            jacobian: kktProblem.jacobian,
            primalRightHandSide: [-4, -3], constraintRightHandSide: [-1])
        let kkt = try kktWorkspace.solve(updatedKKT)
        let kktCase = ValidationCase(id: "internal.sparse.nonlinear-kkt",
            family: "sparse-nonlinear", tier: .standard,
            name: "reusable sparse nonlinear KKT pipeline", metrics: [
                .init(name: "KKT relative residual", observed: kkt.relativeResidual,
                      reference: 0, tolerance: .init(absolute: 1e-12, relative: 0)),
                .init(name: "KKT symbolic analyses", observed: Double(kkt.symbolicAnalyses),
                      reference: 1, tolerance: .init(absolute: 0, relative: 0)),
                .init(name: "KKT numeric factorizations", observed: Double(kkt.numericFactorizations),
                      reference: 2, tolerance: .init(absolute: 0, relative: 0)),
                .init(name: "KKT negative inertia", observed: Double(kkt.inertia?.negative ?? -1),
                      reference: 1, tolerance: .init(absolute: 0, relative: 0)),
            ])

        let netlist = try SpiceNetlist.parse("""
        validation RC low pass
        V1 in 0 DC 1 AC 1
        R1 in out 1k
        C1 out 0 1u
        .OP
        .AC DEC 10 10 10k
        .END
        """)
        let circuitOperatingPoint = try netlist.circuit.dcOperatingPoint()
        guard case .ac(let acRequest)? = netlist.analyses.last else {
            throw NonlinearOptimizationError.invalidConfiguration("SPICE validation lost AC request")
        }
        let circuitSweep = try netlist.circuit.acAnalysis(
            operatingState: circuitOperatingPoint.state, frequencies: acRequest.frequencies,
            excitations: netlist.acExcitations)
        let spiceCase = ValidationCase(id: "internal.circuit.spice-netlist",
            family: "circuit-analysis", tier: .standard,
            name: "SPICE netlist DC and AC integration", metrics: [
                .init(name: "SPICE DC output", observed: circuitOperatingPoint.nodeVoltages[2],
                      reference: 1, tolerance: tolerance),
                .init(name: "SPICE AC point count", observed: Double(circuitSweep.points.count),
                      reference: 31, tolerance: .init(absolute: 0, relative: 0)),
                .init(name: "SPICE AC maximum residual",
                      observed: circuitSweep.points.map(\.residualNorm).max() ?? .infinity,
                      reference: 0, tolerance: .init(absolute: 1e-9, relative: 0)),
            ])

        let daeSystem: TimeIntegrator.DAESystem = { _, y, yd in
            DAEEvaluation.massMatrix([[1, 0], [0, 0]],
                rightHandSide: [-y[0], 1-y[0]-y[1]],
                rightHandSideJacobian: [[-1, 0], [-1, -1]], derivative: yd)
        }
        let daeInitial = try TimeIntegrator.consistentDAEInitialConditions(
            time: 0, initialState: [1, 0.5], initialDerivative: [0, 0],
            freeState: [false, true], system: daeSystem)
        let daeResult = try TimeIntegrator.integrateDAE(from: 0, to: 2,
            initialState: daeInitial.state, initialDerivative: daeInitial.derivative,
            options: .init(absoluteTolerance: 1e-5, relativeTolerance: 1e-4,
                           initialStep: 0.02, maximumStep: 0.05), stopTimes: [0.3],
            events: [.init(direction: .falling, terminal: true)],
            eventFunction: { _, y in [y[0]-0.5] }, system: daeSystem)
        let daeCase = ValidationCase(id: "internal.dae.production",
            family: "time-integration", tier: .standard,
            name: "consistent index-1 DAE initialization and event integration", metrics: [
                .init(name: "DAE initialization residual", observed: daeInitial.residualNorm,
                      reference: 0, tolerance: .init(absolute: 1e-10, relative: 0)),
                .init(name: "DAE terminal event time", observed: daeResult.events.first?.time ?? .infinity,
                      reference: log(2), tolerance: .init(absolute: 3e-3, relative: 0)),
                .init(name: "DAE hard stop observed",
                      observed: daeResult.points.contains { abs($0.time-0.3) < 1e-14 } ? 1 : 0,
                      reference: 1, tolerance: .init(absolute: 0, relative: 0)),
            ])

        let perturbed = NumericalValidation.perturb([1, -2, 3], seed: 42,
                                                     relativeMagnitude: 1e-6)
        let perturbationCase = ValidationCase(id: "internal.reproducibility.perturbation",
            family: "validation-infrastructure", tier: .standard,
            name: "deterministic perturbation reproducibility", metrics:
            zip(perturbed, NumericalValidation.perturb([1, -2, 3], seed: 42,
                                                        relativeMagnitude: 1e-6)).enumerated().map {
                .init(name: "perturbation \($0.offset)", observed: $0.element.0,
                      reference: $0.element.1, tolerance: .init(absolute: 0, relative: 0))
            })

        var cases = [lpCase, qpCase, certificateCase, milpCase, nonlinearCase,
                     presolveCase, sparseCase, kktCase, spiceCase, daeCase, perturbationCase]
        cases += try ExternalValidationProgram.run()
        return ValidationReport(cases: cases)
    }
}
