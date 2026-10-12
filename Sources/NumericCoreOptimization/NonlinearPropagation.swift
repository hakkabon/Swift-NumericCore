import Foundation

public struct NonlinearPropagationOptions: Sendable, Hashable {
    public var maxPasses: Int
    public var tolerance: Double
    public init(maxPasses: Int = 8, tolerance: Double = 1e-10) {
        self.maxPasses = maxPasses; self.tolerance = tolerance
    }
}

public struct NonlinearPropagationResult: Sendable, Hashable {
    public let bounds: [ParameterBound]
    public let passes: Int
    public let boundsTightened: Int
    public let infeasible: Bool
}

/// Performs feasibility-based bound tightening using forward interval
/// evaluation followed by conservative backward graph contraction.
public func propagateNonlinearBounds(
    model: NonlinearModel, constraints: [NonlinearConstraint] = [],
    bounds initialBounds: [ParameterBound], objectiveCutoff: Double? = nil,
    options: NonlinearPropagationOptions = .init()
) throws -> NonlinearPropagationResult {
    try model.validate()
    guard initialBounds.count == model.parameterCount, options.maxPasses > 0,
          options.tolerance.isFinite, options.tolerance >= 0 else {
        throw NonlinearOptimizationError.invalidConfiguration(
            "invalid nonlinear propagation configuration")
    }
    var bounds = initialBounds, tightened = 0
    for pass in 0..<options.maxPasses {
        let before = tightened
        if let expression = model.objective, let objectiveCutoff,
           try !contract(expression, target: .init(upper: objectiveCutoff), bounds: &bounds,
                         tolerance: options.tolerance, tightened: &tightened) {
            return .init(bounds: bounds, passes: pass + 1,
                         boundsTightened: tightened, infeasible: true)
        }
        for constraint in constraints {
            try constraint.expression.validate(parameterCount: model.parameterCount)
            if try !contract(constraint.expression, target: constraint.bound, bounds: &bounds,
                             tolerance: options.tolerance, tightened: &tightened) {
                return .init(bounds: bounds, passes: pass + 1,
                             boundsTightened: tightened, infeasible: true)
            }
        }
        if tightened == before {
            return .init(bounds: bounds, passes: pass + 1,
                         boundsTightened: tightened, infeasible: false)
        }
    }
    return .init(bounds: bounds, passes: options.maxPasses,
                 boundsTightened: tightened, infeasible: false)
}

private func contract(_ expression: NonlinearExpression, target: ParameterBound,
                      bounds: inout [ParameterBound], tolerance: Double,
                      tightened: inout Int) throws -> Bool {
    let analysis = try expression.analyze(bounds: bounds)
    var intervals = analysis.nodes.map(\.interval)
    guard intersect(&intervals[expression.output], boundInterval(target)) else { return false }
    for index in expression.nodes.indices.reversed() {
        let z = intervals[index]
        let valid: Bool
        switch expression.nodes[index] {
        case .constant(let value): valid = z.lower <= value && value <= z.upper
        case .parameter(let parameter):
            let old = boundInterval(bounds[parameter]); var next = old
            valid = intersect(&next, z)
            if valid && changed(old, next, tolerance) {
                bounds[parameter] = parameterBound(next)
                tightened += (next.lower > old.lower ? 1 : 0) + (next.upper < old.upper ? 1 : 0)
            }
        case .add(let a, let b):
            let x = intervals[a], y = intervals[b]
            valid = intersect(&intervals[a], subtract(z, y))
                && intersect(&intervals[b], subtract(z, x))
        case .subtract(let a, let b):
            let x = intervals[a], y = intervals[b]
            valid = intersect(&intervals[a], add(z, y))
                && intersect(&intervals[b], subtract(x, z))
        case .negate(let a):
            valid = intersect(&intervals[a], makeInterval(-z.upper, -z.lower))
        case .multiply(let a, let b) where a == b:
            if z.upper < 0 { valid = false }
            else {
                let radius = sqrt(max(0, z.upper))
                valid = intersect(&intervals[a], makeInterval(-radius, radius))
            }
        case .multiply(let a, let b):
            let x = intervals[a], y = intervals[b]
            valid = (!excludesZero(y) || intersect(&intervals[a], divide(z, y)))
                && (!excludesZero(x) || intersect(&intervals[b], divide(z, x)))
        case .divide(let a, let b):
            let x = intervals[a], y = intervals[b]
            valid = intersect(&intervals[a], multiply(z, y))
                && (!excludesZero(z) || intersect(&intervals[b], divide(x, z)))
        case .exp(let a):
            valid = z.upper > 0 && intersect(&intervals[a], makeInterval(
                z.lower > 0 ? Foundation.log(z.lower) : -.infinity, Foundation.log(z.upper)))
        case .log(let a):
            valid = intersect(&intervals[a], makeInterval(Foundation.exp(z.lower), Foundation.exp(z.upper)))
        case .sqrt(let a):
            var positive = z
            valid = intersect(&positive, makeInterval(0, .infinity))
                && intersect(&intervals[a], makeInterval(
                    positive.lower * positive.lower, positive.upper * positive.upper))
        case .pow(let a, let exponent) where exponent == 1:
            valid = intersect(&intervals[a], z)
        case .pow(let a, let exponent) where exponent == 2:
            if z.upper < 0 { valid = false }
            else {
                let radius = sqrt(max(0, z.upper))
                valid = intersect(&intervals[a], makeInterval(-radius, radius))
            }
        default: valid = true
        }
        if !valid { return false }
    }
    return true
}

private func makeInterval(_ lower: Double, _ upper: Double) -> NonlinearInterval {
    NonlinearInterval(lower: lower, upper: upper) ?? .whole
}
private func boundInterval(_ value: ParameterBound) -> NonlinearInterval {
    makeInterval(value.lower ?? -.infinity, value.upper ?? .infinity)
}
private func parameterBound(_ value: NonlinearInterval) -> ParameterBound {
    .init(lower: value.lower.isFinite ? value.lower : nil,
          upper: value.upper.isFinite ? value.upper : nil)
}
private func intersect(_ value: inout NonlinearInterval, _ other: NonlinearInterval) -> Bool {
    guard let result = NonlinearInterval(lower: max(value.lower, other.lower),
                                         upper: min(value.upper, other.upper)) else { return false }
    value = result; return true
}
private func add(_ a: NonlinearInterval, _ b: NonlinearInterval) -> NonlinearInterval {
    makeInterval(a.lower + b.lower, a.upper + b.upper)
}
private func subtract(_ a: NonlinearInterval, _ b: NonlinearInterval) -> NonlinearInterval {
    makeInterval(a.lower - b.upper, a.upper - b.lower)
}
private func multiply(_ a: NonlinearInterval, _ b: NonlinearInterval) -> NonlinearInterval {
    let values = [a.lower*b.lower, a.lower*b.upper, a.upper*b.lower, a.upper*b.upper]
    guard values.allSatisfy({ !$0.isNaN }) else { return .whole }
    return makeInterval(values.min()!, values.max()!)
}
private func divide(_ a: NonlinearInterval, _ b: NonlinearInterval) -> NonlinearInterval {
    excludesZero(b) ? multiply(a, makeInterval(1 / b.upper, 1 / b.lower)) : .whole
}
private func excludesZero(_ value: NonlinearInterval) -> Bool {
    value.upper < 0 || value.lower > 0
}
private func changed(_ a: NonlinearInterval, _ b: NonlinearInterval, _ tolerance: Double) -> Bool {
    b.lower > a.lower + tolerance || b.upper < a.upper - tolerance
}
