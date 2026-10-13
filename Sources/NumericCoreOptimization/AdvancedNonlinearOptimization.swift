import Foundation

public struct NewtonCGOptions: Sendable, Hashable {
    public var maxIterations: Int; public var maxCGIterations: Int
    public var gradientTolerance: Double; public var stepTolerance: Double
    public var initialRadius: Double; public var maximumRadius: Double
    public var acceptanceRatio: Double
    public init(maxIterations: Int = 200, maxCGIterations: Int = 100,
                gradientTolerance: Double = 1e-8, stepTolerance: Double = 1e-12,
                initialRadius: Double = 1, maximumRadius: Double = 1e4,
                acceptanceRatio: Double = 0.1) {
        self.maxIterations = maxIterations; self.maxCGIterations = maxCGIterations
        self.gradientTolerance = gradientTolerance; self.stepTolerance = stepTolerance
        self.initialRadius = initialRadius; self.maximumRadius = maximumRadius
        self.acceptanceRatio = acceptanceRatio
    }
}

public struct NewtonCGResult: Sendable, Hashable {
    public let point: [Double]; public let objective: Double; public let gradient: [Double]
    public let iterations: Int; public let evaluations: Int; public let hessianProducts: Int
    public let acceptedSteps: Int; public let finalRadius: Double
    public let termination: NonlinearTermination
}

/// Matrix-free Steihaug trust-region Newton method. Negative curvature and
/// boundary hits are handled inside truncated conjugate gradient.
public enum TrustRegionNewtonCG {
    public typealias Objective = ([Double]) throws -> (value: Double, gradient: [Double])
    public typealias HessianProduct = (_ point: [Double], _ direction: [Double]) throws -> [Double]

    public static func minimize(initial: [Double], options: NewtonCGOptions = .init(),
                                objective: Objective,
                                hessianProduct: HessianProduct) throws -> NewtonCGResult {
        try validate(initial, options)
        var point = initial, current = try evaluate(objective, point), evaluations = 1
        var products = 0, accepted = 0, radius = options.initialRadius
        for iteration in 0..<options.maxIterations {
            if normInfinity(current.gradient) <= options.gradientTolerance {
                return result(point, current, iteration, evaluations, products, accepted,
                              radius, .convergedGradient)
            }
            let cg = try steihaug(point, current.gradient, radius, options.maxCGIterations,
                                  hessianProduct)
            products += cg.products
            let stepNorm = norm(cg.step)
            if stepNorm <= options.stepTolerance {
                return result(point, current, iteration, evaluations, products, accepted,
                              radius, .convergedStep)
            }
            let predicted = -(dot(current.gradient, cg.step) + 0.5 * dot(cg.step, cg.product))
            if !predicted.isFinite || predicted <= 0 { radius *= 0.25; continue }
            let candidate = zip(point, cg.step).map { $0 + $1 }
            let next = try evaluate(objective, candidate); evaluations += 1
            let ratio = (current.value - next.value) / predicted
            if ratio < 0.25 { radius *= 0.25 }
            else if ratio > 0.75 && stepNorm >= 0.9 * radius {
                radius = min(2 * radius, options.maximumRadius)
            }
            if ratio > options.acceptanceRatio {
                point = candidate; current = next; accepted += 1
            }
        }
        return result(point, current, options.maxIterations, evaluations, products, accepted,
                      radius, .iterationLimit)
    }

    private static func steihaug(_ point: [Double], _ gradient: [Double], _ radius: Double,
                                 _ limit: Int, _ hessian: HessianProduct) throws
        -> (step: [Double], product: [Double], products: Int) {
        var step = [Double](repeating: 0, count: gradient.count)
        var residual = gradient.map(-), direction = residual
        var rr = dot(residual, residual), products = 0
        let target = 0.1 * sqrt(rr)
        for _ in 0..<limit {
            if sqrt(rr) <= target { break }
            let hd = try checkedVector(hessian(point, direction), count: point.count,
                                       name: "Hessian-vector product")
            products += 1
            let curvature = dot(direction, hd)
            if curvature <= 0 {
                axpy(&step, boundaryTau(step, direction, radius), direction); break
            }
            let alpha = rr / curvature
            var trial = step; axpy(&trial, alpha, direction)
            if norm(trial) >= radius {
                axpy(&step, boundaryTau(step, direction, radius), direction); break
            }
            step = trial; axpy(&residual, -alpha, hd)
            let next = dot(residual, residual)
            if sqrt(next) <= target { break }
            let beta = next / rr
            direction = zip(residual, direction).map { $0 + beta * $1 }
            rr = next
        }
        let hp = try checkedVector(hessian(point, step), count: point.count,
                                   name: "Hessian-vector product")
        return (step, hp, products + 1)
    }

    private static func evaluate(_ objective: Objective, _ point: [Double]) throws
        -> (value: Double, gradient: [Double]) {
        let value = try objective(point)
        guard value.value.isFinite else {
            throw NonlinearOptimizationError.invalidEvaluation("non-finite objective")
        }
        return (value.value, try checkedVector(value.gradient, count: point.count, name: "gradient"))
    }
    private static func validate(_ point: [Double], _ o: NewtonCGOptions) throws {
        guard !point.isEmpty, point.allSatisfy(\.isFinite), o.maxIterations > 0,
              o.maxCGIterations > 0, o.gradientTolerance.isFinite, o.gradientTolerance > 0,
              o.stepTolerance.isFinite, o.stepTolerance > 0, o.initialRadius.isFinite,
              o.initialRadius > 0, o.maximumRadius.isFinite,
              o.maximumRadius >= o.initialRadius, o.acceptanceRatio.isFinite,
              o.acceptanceRatio >= 0, o.acceptanceRatio < 0.25 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid trust-region Newton-CG options")
        }
    }
    private static func result(_ point: [Double], _ evaluation: (value: Double, gradient: [Double]),
                               _ iterations: Int, _ evaluations: Int, _ products: Int,
                               _ accepted: Int, _ radius: Double,
                               _ termination: NonlinearTermination) -> NewtonCGResult {
        .init(point: point, objective: evaluation.value, gradient: evaluation.gradient,
              iterations: iterations, evaluations: evaluations, hessianProducts: products,
              acceptedSteps: accepted, finalRadius: radius, termination: termination)
    }
}

public struct PowellOptions: Sendable, Hashable {
    public var maxIterations: Int; public var maxLineIterations: Int
    public var stepTolerance: Double; public var objectiveTolerance: Double
    public var initialStep: Double
    public init(maxIterations: Int = 500, maxLineIterations: Int = 80,
                stepTolerance: Double = 1e-8, objectiveTolerance: Double = 1e-10,
                initialStep: Double = 1) {
        self.maxIterations = maxIterations; self.maxLineIterations = maxLineIterations
        self.stepTolerance = stepTolerance; self.objectiveTolerance = objectiveTolerance
        self.initialStep = initialStep
    }
}
public struct PowellResult: Sendable, Hashable {
    public let point: [Double]; public let objective: Double
    public let iterations: Int; public let evaluations: Int
    public let termination: NonlinearTermination
}

/// Powell's derivative-free conjugate direction-set method.
public enum PowellDirectionSet {
    public typealias Objective = ([Double]) throws -> Double
    public static func minimize(initial: [Double], options: PowellOptions = .init(),
                                objective: Objective) throws -> PowellResult {
        try validate(initial, options)
        var point = initial, value = try evaluate(objective, point), evaluations = 1
        var directions = initial.indices.map { index -> [Double] in
            var value = [Double](repeating: 0, count: initial.count)
            value[index] = options.initialStep; return value
        }
        for iteration in 0..<options.maxIterations {
            let start = point, startValue = value
            var largest = 0.0, largestIndex = 0
            for index in directions.indices {
                let before = value
                let line = try lineMinimize(point, directions[index], value, options, objective)
                point = line.point; value = line.value; evaluations += line.evaluations
                if before - value > largest { largest = before - value; largestIndex = index }
            }
            let displacement = zip(point, start).map { $0 - $1 }, sweepStep = norm(displacement)
            let line = try lineMinimize(point, displacement, value, options, objective)
            point = line.point; value = line.value; evaluations += line.evaluations
            directions[largestIndex] = displacement
            if sweepStep <= options.stepTolerance {
                return .init(point: point, objective: value, iterations: iteration + 1,
                             evaluations: evaluations, termination: .convergedStep)
            }
            if 2 * abs(startValue - value) <= options.objectiveTolerance
                * (abs(startValue) + abs(value) + 1) {
                return .init(point: point, objective: value, iterations: iteration + 1,
                             evaluations: evaluations, termination: .convergedObjective)
            }
        }
        return .init(point: point, objective: value, iterations: options.maxIterations,
                     evaluations: evaluations, termination: .iterationLimit)
    }

    private static func lineMinimize(_ point: [Double], _ direction: [Double], _ center: Double,
                                     _ options: PowellOptions, _ objective: Objective) throws
        -> (point: [Double], value: Double, evaluations: Int) {
        if norm(direction) == 0 { return (point, center, 0) }
        var calls = 0
        func sample(_ alpha: Double) throws -> Double {
            calls += 1
            return try evaluate(objective, zip(point, direction).map { $0 + alpha * $1 })
        }
        let plus = try sample(1), minus = try sample(-1)
        var lo: Double, hi: Double
        if plus >= center && minus >= center { lo = -1; hi = 1 }
        else {
            let sign = plus < minus ? 1.0 : -1.0
            var a = 0.0, b = sign, fb = sign > 0 ? plus : minus
            var c = b + sign * 1.61803398875, fc = try sample(c)
            while fc < fb && calls < options.maxLineIterations / 2 {
                a = b; b = c; fb = fc
                c = b + sign * abs(b - a) * 1.61803398875; fc = try sample(c)
            }
            lo = min(a, c); hi = max(a, c)
        }
        let phi = 0.6180339887498949
        var x1 = hi - phi * (hi - lo), x2 = lo + phi * (hi - lo)
        var f1 = try sample(x1), f2 = try sample(x2)
        while calls < options.maxLineIterations && abs(hi - lo) > options.stepTolerance {
            if f1 < f2 { hi = x2; x2 = x1; f2 = f1; x1 = hi - phi * (hi - lo); f1 = try sample(x1) }
            else { lo = x1; x1 = x2; f1 = f2; x2 = lo + phi * (hi - lo); f2 = try sample(x2) }
        }
        let alpha = f1 < f2 ? x1 : x2, best = min(f1, f2)
        return (zip(point, direction).map { $0 + alpha * $1 }, best, calls)
    }
    private static func evaluate(_ objective: Objective, _ point: [Double]) throws -> Double {
        let value = try objective(point)
        guard value.isFinite else { throw NonlinearOptimizationError.invalidEvaluation("non-finite objective") }
        return value
    }
    private static func validate(_ point: [Double], _ o: PowellOptions) throws {
        guard !point.isEmpty, point.allSatisfy(\.isFinite), o.maxIterations > 0,
              o.maxLineIterations > 0, o.stepTolerance.isFinite, o.stepTolerance > 0,
              o.objectiveTolerance.isFinite, o.objectiveTolerance > 0,
              o.initialStep.isFinite, o.initialStep > 0 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid Powell direction-set options")
        }
    }
}

private func checkedVector(_ value: [Double], count: Int, name: String) throws -> [Double] {
    guard value.count == count, value.allSatisfy(\.isFinite) else {
        throw NonlinearOptimizationError.invalidEvaluation("invalid \(name)")
    }
    return value
}
private func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
private func norm(_ a: [Double]) -> Double { sqrt(dot(a, a)) }
private func normInfinity(_ a: [Double]) -> Double { a.map(abs).max() ?? 0 }
private func axpy(_ x: inout [Double], _ alpha: Double, _ y: [Double]) {
    for index in x.indices { x[index] += alpha * y[index] }
}
private func boundaryTau(_ point: [Double], _ direction: [Double], _ radius: Double) -> Double {
    let a = dot(direction, direction), b = 2 * dot(point, direction)
    let c = dot(point, point) - radius * radius
    return (-b + sqrt(max(0, b * b - 4 * a * c))) / (2 * a)
}
