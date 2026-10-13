import Foundation

public enum DerivativeFreeTermination: Sendable, Hashable {
    case converged
    case iterationLimit
    case evaluationLimit
    case cancelled
}

public struct DerivativeFreeIteration: Sendable, Hashable {
    public let iteration: Int
    public let point: [Double]
    public let objective: Double
    public let evaluations: Int
    public let size: Double
}

public struct NelderMeadOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var maxEvaluations: Int
    public var initialStep: Double
    public var pointTolerance: Double
    public var objectiveTolerance: Double
    public var reflection: Double
    public var expansion: Double
    public var contraction: Double
    public var shrink: Double

    public init(maxIterations: Int = 1_000, maxEvaluations: Int = 10_000,
                initialStep: Double = 0.05, pointTolerance: Double = 1e-8,
                objectiveTolerance: Double = 1e-10, reflection: Double = 1,
                expansion: Double = 2, contraction: Double = 0.5,
                shrink: Double = 0.5) {
        self.maxIterations = maxIterations; self.maxEvaluations = maxEvaluations
        self.initialStep = initialStep; self.pointTolerance = pointTolerance
        self.objectiveTolerance = objectiveTolerance; self.reflection = reflection
        self.expansion = expansion; self.contraction = contraction; self.shrink = shrink
    }
}

public struct NelderMeadResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let iterations: Int
    public let evaluations: Int
    public let simplexDiameter: Double
    public let objectiveSpread: Double
    public let termination: DerivativeFreeTermination
}

/// Bound-aware Nelder-Mead simplex minimization using objective values only.
public enum NelderMead {
    public typealias Objective = ([Double]) throws -> Double
    public typealias Observer = (DerivativeFreeIteration) -> Bool

    public static func minimize(initial: [Double], bounds: [ParameterBound]? = nil,
                                options: NelderMeadOptions = .init(),
                                observer: Observer? = nil,
                                objective: Objective) throws -> NelderMeadResult {
        let box = try dfValidate(initial, bounds, options)
        var vertices = [dfProject(initial, box)]
        for dimension in initial.indices {
            var vertex = vertices[0]
            let delta = options.initialStep * max(1, abs(vertex[dimension]))
            vertex[dimension] += delta; vertex = dfProject(vertex, box)
            if vertex[dimension] == vertices[0][dimension] {
                vertex[dimension] -= delta; vertex = dfProject(vertex, box)
            }
            guard vertex != vertices[0] else {
                throw NonlinearOptimizationError.invalidConfiguration(
                    "Nelder-Mead requires non-fixed parameter bounds")
            }
            vertices.append(vertex)
        }
        var values: [Double] = []
        for vertex in vertices { values.append(try dfEvaluate(objective, vertex)) }
        var evaluations = values.count

        for iteration in 0..<options.maxIterations {
            dfSort(&vertices, &values)
            let diameter = dfDiameter(vertices), spread = values.last! - values[0]
            if diameter <= options.pointTolerance && spread <= options.objectiveTolerance {
                return dfNelderResult(vertices, values, iteration, evaluations, .converged)
            }
            if evaluations >= options.maxEvaluations {
                return dfNelderResult(vertices, values, iteration, evaluations, .evaluationLimit)
            }
            if observer?(.init(iteration: iteration, point: vertices[0], objective: values[0],
                               evaluations: evaluations, size: diameter)) == false {
                return dfNelderResult(vertices, values, iteration, evaluations, .cancelled)
            }
            let centroid = dfCentroid(vertices.dropLast())
            let reflected = dfProject(dfAffine(centroid, vertices.last!, options.reflection), box)
            let reflectedValue = try dfEvaluate(objective, reflected); evaluations += 1

            if reflectedValue < values[0] && evaluations < options.maxEvaluations {
                let expanded = dfProject(dfAffine(centroid, reflected, -options.expansion), box)
                let expandedValue = try dfEvaluate(objective, expanded); evaluations += 1
                if expandedValue < reflectedValue {
                    vertices[vertices.count - 1] = expanded; values[values.count - 1] = expandedValue
                } else {
                    vertices[vertices.count - 1] = reflected; values[values.count - 1] = reflectedValue
                }
            } else if reflectedValue < values[values.count - 2] {
                vertices[vertices.count - 1] = reflected; values[values.count - 1] = reflectedValue
            } else if evaluations < options.maxEvaluations {
                let outside = reflectedValue < values.last!
                let target = outside ? reflected : vertices.last!
                let contracted = dfProject(zip(centroid, target).map {
                    $0 + options.contraction * ($1 - $0)
                }, box)
                let contractedValue = try dfEvaluate(objective, contracted); evaluations += 1
                if contractedValue < (outside ? reflectedValue : values.last!) {
                    vertices[vertices.count - 1] = contracted
                    values[values.count - 1] = contractedValue
                } else {
                    for index in 1..<vertices.count where evaluations < options.maxEvaluations {
                        vertices[index] = dfProject(zip(vertices[0], vertices[index]).map {
                            $0 + options.shrink * ($1 - $0)
                        }, box)
                        values[index] = try dfEvaluate(objective, vertices[index]); evaluations += 1
                    }
                }
            }
        }
        dfSort(&vertices, &values)
        return dfNelderResult(vertices, values, options.maxIterations, evaluations, .iterationLimit)
    }
}

public struct PatternSearchOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var maxEvaluations: Int
    public var initialStep: Double
    public var minimumStep: Double
    public var contraction: Double
    public var expansion: Double
    public var objectiveTolerance: Double

    public init(maxIterations: Int = 1_000, maxEvaluations: Int = 10_000,
                initialStep: Double = 1, minimumStep: Double = 1e-8,
                contraction: Double = 0.5, expansion: Double = 1.25,
                objectiveTolerance: Double = 1e-12) {
        self.maxIterations = maxIterations; self.maxEvaluations = maxEvaluations
        self.initialStep = initialStep; self.minimumStep = minimumStep
        self.contraction = contraction; self.expansion = expansion
        self.objectiveTolerance = objectiveTolerance
    }
}

public struct PatternSearchResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let iterations: Int
    public let evaluations: Int
    public let successfulPolls: Int
    public let finalStep: Double
    public let termination: DerivativeFreeTermination
}

/// Deterministic coordinate pattern search for nonsmooth, box-constrained objectives.
public enum CoordinatePatternSearch {
    public typealias Objective = NelderMead.Objective
    public typealias Observer = NelderMead.Observer

    public static func minimize(initial: [Double], bounds: [ParameterBound]? = nil,
                                options: PatternSearchOptions = .init(),
                                observer: Observer? = nil,
                                objective: Objective) throws -> PatternSearchResult {
        let box = try dfValidate(initial, bounds, options)
        var point = dfProject(initial, box), value = try dfEvaluate(objective, point)
        var evaluations = 1, successes = 0, step = options.initialStep
        for iteration in 0..<options.maxIterations {
            if step <= options.minimumStep {
                return .init(point: point, objective: value, iterations: iteration,
                             evaluations: evaluations, successfulPolls: successes,
                             finalStep: step, termination: .converged)
            }
            if evaluations >= options.maxEvaluations {
                return .init(point: point, objective: value, iterations: iteration,
                             evaluations: evaluations, successfulPolls: successes,
                             finalStep: step, termination: .evaluationLimit)
            }
            if observer?(.init(iteration: iteration, point: point, objective: value,
                               evaluations: evaluations, size: step)) == false {
                return .init(point: point, objective: value, iterations: iteration,
                             evaluations: evaluations, successfulPolls: successes,
                             finalStep: step, termination: .cancelled)
            }
            var bestPoint = point, bestValue = value
            for dimension in point.indices {
                for sign in [1.0, -1.0] where evaluations < options.maxEvaluations {
                    var candidate = point; candidate[dimension] += sign * step
                    candidate = dfProject(candidate, box)
                    if candidate == point { continue }
                    let candidateValue = try dfEvaluate(objective, candidate); evaluations += 1
                    if candidateValue < bestValue {
                        bestPoint = candidate; bestValue = candidateValue
                    }
                }
            }
            if bestValue + options.objectiveTolerance < value {
                point = bestPoint; value = bestValue; successes += 1
                step *= options.expansion
            } else {
                step *= options.contraction
            }
        }
        return .init(point: point, objective: value, iterations: options.maxIterations,
                     evaluations: evaluations, successfulPolls: successes,
                     finalStep: step, termination: .iterationLimit)
    }
}

private func dfValidate(_ point: [Double], _ bounds: [ParameterBound]?,
                        _ options: NelderMeadOptions) throws -> [ParameterBound] {
    guard options.maxIterations > 0, options.maxEvaluations >= point.count + 1,
          options.initialStep.isFinite, options.initialStep > 0,
          options.pointTolerance.isFinite, options.pointTolerance > 0,
          options.objectiveTolerance.isFinite, options.objectiveTolerance >= 0,
          options.reflection > 0, options.expansion > 1,
          options.contraction > 0, options.contraction < 1,
          options.shrink > 0, options.shrink < 1 else {
        throw NonlinearOptimizationError.invalidConfiguration("invalid Nelder-Mead options")
    }
    return try dfBox(point, bounds)
}

private func dfValidate(_ point: [Double], _ bounds: [ParameterBound]?,
                        _ options: PatternSearchOptions) throws -> [ParameterBound] {
    guard options.maxIterations > 0, options.maxEvaluations > 0,
          options.initialStep.isFinite, options.initialStep > 0,
          options.minimumStep.isFinite, options.minimumStep > 0,
          options.minimumStep < options.initialStep,
          options.contraction > 0, options.contraction < 1,
          options.expansion >= 1, options.objectiveTolerance.isFinite,
          options.objectiveTolerance >= 0 else {
        throw NonlinearOptimizationError.invalidConfiguration("invalid pattern-search options")
    }
    return try dfBox(point, bounds)
}

private func dfBox(_ point: [Double], _ bounds: [ParameterBound]?) throws -> [ParameterBound] {
    guard !point.isEmpty, point.allSatisfy(\.isFinite) else {
        throw NonlinearOptimizationError.invalidInitialPoint
    }
    let box = bounds ?? [ParameterBound](repeating: .free, count: point.count)
    guard box.count == point.count, box.allSatisfy({ bound in
        (bound.lower?.isFinite ?? true) && (bound.upper?.isFinite ?? true)
            && (bound.lower ?? -.infinity) <= (bound.upper ?? .infinity)
    }) else { throw NonlinearOptimizationError.invalidConfiguration("invalid parameter bounds") }
    return box
}

private func dfProject(_ point: [Double], _ bounds: [ParameterBound]) -> [Double] {
    zip(point, bounds).map { min($1.upper ?? .infinity, max($1.lower ?? -.infinity, $0)) }
}

private func dfEvaluate(_ objective: NelderMead.Objective, _ point: [Double]) throws -> Double {
    let value = try objective(point)
    guard value.isFinite else {
        throw NonlinearOptimizationError.invalidEvaluation("non-finite derivative-free objective")
    }
    return value
}

private func dfSort(_ vertices: inout [[Double]], _ values: inout [Double]) {
    let ordered = zip(vertices, values).sorted { $0.1 < $1.1 }
    vertices = ordered.map(\.0); values = ordered.map(\.1)
}

private func dfCentroid(_ vertices: ArraySlice<[Double]>) -> [Double] {
    var result = [Double](repeating: 0, count: vertices.first!.count)
    for vertex in vertices { for index in result.indices { result[index] += vertex[index] } }
    return result.map { $0 / Double(vertices.count) }
}

/// `factor > 0` reflects away from `other`; a negative factor expands toward it.
private func dfAffine(_ center: [Double], _ other: [Double], _ factor: Double) -> [Double] {
    zip(center, other).map { $0 + factor * ($0 - $1) }
}

private func dfDiameter(_ vertices: [[Double]]) -> Double {
    vertices.dropFirst().map { vertex in
        sqrt(zip(vertex, vertices[0]).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
    }.max() ?? 0
}

private func dfNelderResult(_ vertices: [[Double]], _ values: [Double], _ iterations: Int,
                            _ evaluations: Int, _ termination: DerivativeFreeTermination)
    -> NelderMeadResult {
    .init(point: vertices[0], objective: values[0], iterations: iterations,
          evaluations: evaluations, simplexDiameter: dfDiameter(vertices),
          objectiveSpread: values.last! - values[0], termination: termination)
}
