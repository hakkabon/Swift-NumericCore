import Foundation
import NumericCore
import NumericCoreSparse

func releaseValidationCases() throws -> [ValidationCase] {
    [try suppliedGapCase()] + (try decompositionCases())
        + [try scaledSparseSolveCase(), try checkpointedAdjointCase()]
}

private func suppliedGapCase() throws -> ValidationCase {
    let fixed = try SparseLinearProblem(
        objective: [1], rows: 0, columns: 1, rowPointers: [0],
        columnIndices: [], values: [], rowBounds: [], variableBounds: [.init(lower: 2, upper: 2)])
    let model = try SparseLinearProblem(
        objective: [1], rows: 0, columns: 1, rowPointers: [0],
        columnIndices: [], values: [], rowBounds: [], variableBounds: [.init(lower: 0, upper: 2)])
    let result = try ProductionLinearSolver.solve(fixed)
    let certificate = try OptimizationCertifier.certifyLinear(problem: model, result: result, globalGap: 0)
    return .init(id: "internal.certificate.supplied-gap", family: "optimization-certification",
                 tier: .standard, name: "Supplied gap on a feasible suboptimal LP point", metrics: [
        exactCheck("feasibility claim verified", certificate.claim == .feasibility && certificate.verified),
        exactCheck("supplied gap passed scalar check",
                   certificate.metrics.contains { $0.name == "caller-supplied gap" && $0.passed }),
        .init(name: "objective above known minimum", observed: result.objective, reference: 2, tolerance: .init()),
    ])
}

private func decompositionCases() throws -> [ValidationCase] {
    let first = try SparseLinearProblem(
        objective: [1], rows: 0, columns: 1, rowPointers: [0],
        columnIndices: [], values: [], rowBounds: [], variableBounds: [.init(lower: 0, upper: 10)])
    let recourse = try SparseLinearProblem(
        objective: [4], rows: 1, columns: 1, rowPointers: [0, 1], columnIndices: [0],
        values: [1], rowBounds: [.init(lower: 2)], variableBounds: [.init(lower: 0, upper: 10)])
    let coupling = try SparseMatrix<Double>(
        rows: 1, cols: 1, rowPointers: [0, 1], columnIndices: [0], values: [1])
    let model = BendersProblem(firstStage: first, recourse: recourse, coupling: coupling)
    let limited = try BendersSolver.solve(model, options: .init(maxIterations: 1))
    let limitOptions = DistributedBendersOptions(maxRounds: 1)
    let partial = try DistributedBendersCoordinator(problem: model, runID: "release-limit", options: limitOptions)
    try completeBendersRounds(partial, maximum: limitOptions.maxRounds)
    let progress = try partial.progress()
    let boundsOnly = try DistributedBendersCoordinator.verify(
        problem: model, proof: partial.exportProof(), options: limitOptions)
    let limitCase = ValidationCase(id: "internal.benders.limits", family: "decomposition",
                                  tier: .standard, name: "Benders limits retain partial evidence", metrics: [
        exactCheck("local iteration limit", limited.termination == .iterationLimit),
        exactCheck("local bounds bracket the optimum",
                   limited.lowerBound.map { $0 <= 2 } == true && limited.upperBound.map { $0 > 2 } == true),
        exactCheck("distributed round limit", progress.status == .roundLimit),
        exactCheck("partial distributed proof replays bounds", boundsOnly.claim == .bounds),
    ])

    let options = DistributedBendersOptions(maxRounds: 10)
    let coordinator = try DistributedBendersCoordinator(problem: model, runID: "release-replay", options: options)
    try completeBendersRounds(coordinator, maximum: options.maxRounds)
    let proof = try coordinator.exportProof()
    let audit = try DistributedBendersCoordinator.verify(problem: model, proof: proof, options: options)
    let altered = try alteredBendersProof(proof)
    let rejected = (try? DistributedBendersCoordinator.verify(problem: model, proof: altered, options: options)) == nil
    let proofCase = ValidationCase(id: "internal.benders.proof-replay", family: "decomposition",
                                  tier: .standard, name: "Replay and rejection of altered Benders evidence", metrics: [
        exactCheck("valid proof replays optimality", audit.claim == .optimality && audit.verifiedSubproblems > 0),
        .init(name: "replayed lower bound", observed: audit.lowerBound ?? .infinity, reference: 2, tolerance: .init()),
        .init(name: "replayed upper bound", observed: audit.upperBound ?? .infinity, reference: 2, tolerance: .init()),
        exactCheck("altered witness rejected", rejected),
    ])
    return [limitCase, proofCase]
}

private func completeBendersRounds(_ coordinator: DistributedBendersCoordinator, maximum: UInt64) throws {
    for _ in 0..<maximum {
        guard try coordinator.progress().status == .awaitingReplies else { break }
        for job in try coordinator.pendingJobs() {
            try coordinator.submit(DistributedBendersCoordinator.executeJob(job.json))
        }
    }
}

private func alteredBendersProof(_ proof: String) throws -> String {
    guard var document = try JSONSerialization.jsonObject(with: Data(proof.utf8)) as? [String: Any],
          var rounds = document["rounds"] as? [[String: Any]], !rounds.isEmpty,
          var master = rounds[0]["master"] as? [String: Any],
          var point = master["point"] as? [Double], !point.isEmpty else {
        throw NonlinearOptimizationError.invalidEvaluation("validation proof omitted its first master point")
    }
    point[0] = 1e6
    master["point"] = point
    rounds[0]["master"] = master
    document["rounds"] = rounds
    return String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self)
}

private func scaledSparseSolveCase() throws -> ValidationCase {
    let matrix = try SparseMatrix<Double>(
        rows: 3, cols: 3, rowPointers: [0, 2, 5, 7], columnIndices: [0, 1, 0, 1, 2, 1, 2],
        values: [4e-6, 1e-6, 1, 3, 1, 1e6, 2e6])
    let factor = try SparseFactorizationPlan(matrix: matrix).factor(
        matrix: matrix, method: .lu, options: .init(pivotTolerance: 1e-15))
    let solve = try factor.solveRefined([2e-6, -2, 4e6])
    let forwardError = zip(solve.solution, [1.0, -2, 3]).map { abs($0 - $1) }.max() ?? .infinity
    return .init(id: "internal.sparse.scaled-solve", family: "sparse-linear-algebra",
                 tier: .standard, name: "Sparse LU with row scales spanning twelve orders", metrics: [
        .init(name: "forward infinity error", observed: forwardError, reference: 0,
              tolerance: .init(absolute: 1e-9, relative: 0)),
        .init(name: "normwise backward error", observed: solve.backwardError, reference: 0,
              tolerance: .init(absolute: 1e-12, relative: 0)),
    ])
}

private func checkpointedAdjointCase() throws -> ValidationCase {
    // ẏ + y = p on a fixed, nonuniform grid. J = y(final) + Σ h·y².
    let times = [0.0, 0.1, 0.27, 0.45, 0.7]
    let load = 2.0, initial = 0.25, epsilon = 1e-5
    let residual = NonlinearExpression(
        nodes: [.parameter(2), .parameter(1), .add(0, 1), .parameter(3), .subtract(2, 3)], output: 4)
    let model = try EngineeringModel(
        unknowns: [.init(name: "y", unit: "1", role: .differential)],
        parameters: [.init(name: "p", unit: "1", value: load)],
        elements: [.init(name: "balance", kind: "scalar", ports: [.init(name: "y", unknown: 0)],
            equations: [.init(row: 0, expression: residual)])])
    let trajectory = try EngineeringTrajectory(model: model, times: times, initialState: [initial],
                                               options: .init(checkpointStride: 2))
    let result = try trajectory.adjoints([
        .init(name: "response", running: .init(nodes: [.parameter(1), .multiply(0, 0)], output: 1),
              terminal: .init(nodes: [.parameter(1)], output: 0)),
    ])
    let gradient = result.responses[0]
    func referenceObjective(_ load: Double, _ initial: Double) -> Double {
        var state = initial
        var running = 0.0
        for (left, right) in zip(times, times.dropFirst()) {
            let step = right - left
            state = (state + step * load) / (1 + step)
            running += step * state * state
        }
        return running + state
    }
    let loadDifference = (referenceObjective(load + epsilon, initial)
        - referenceObjective(load - epsilon, initial)) / (2 * epsilon)
    let initialDifference = (referenceObjective(load, initial + epsilon)
        - referenceObjective(load, initial - epsilon)) / (2 * epsilon)
    let tolerance = ValidationTolerance(absolute: 1e-8, relative: 0)
    return .init(id: "internal.adjoint.checkpointed", family: "engineering-sensitivity",
                 tier: .standard, name: "Checkpointed backward-Euler adjoint", metrics: [
        .init(name: "objective", observed: gradient.value, reference: referenceObjective(load, initial),
              tolerance: tolerance),
        .init(name: "load derivative", observed: gradient.parameterGradient[0], reference: loadDifference,
              tolerance: tolerance),
        .init(name: "initial-state derivative", observed: gradient.initialStateGradient[0],
              reference: initialDifference, tolerance: tolerance),
        exactCheck("checkpoint replay and transpose solves", result.replayedSteps == 2 && result.transposeSolves == 4),
    ])
}

private func exactCheck(_ name: String, _ passed: Bool) -> ValidationMetric {
    .init(name: name, observed: passed ? 1 : 0, reference: 1, tolerance: .init(absolute: 0, relative: 0))
}
