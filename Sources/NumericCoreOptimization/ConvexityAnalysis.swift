import Foundation

/// Conservative curvature classification over a parameter box.
public enum ExpressionConvexity: Sendable, Hashable {
    case constant, affine, convex, concave, unknown

    public var isConvex: Bool { self == .constant || self == .affine || self == .convex }
    public var isConcave: Bool { self == .constant || self == .affine || self == .concave }
    fileprivate var negated: Self {
        switch self { case .convex: .concave; case .concave: .convex; default: self }
    }
}

public struct NonlinearInterval: Sendable, Hashable {
    public let lower: Double
    public let upper: Double
    public init?(lower: Double, upper: Double) {
        guard !lower.isNaN, !upper.isNaN, lower <= upper else { return nil }
        self.lower = lower; self.upper = upper
    }
    public static let whole = Self(lower: -.infinity, upper: .infinity)!
    public var isFinite: Bool { lower.isFinite && upper.isFinite }
    public var isPoint: Bool { lower == upper }
}

public struct NonlinearNodeAnalysis: Sendable, Hashable {
    public let interval: NonlinearInterval
    public let convexity: ExpressionConvexity
}

public struct NonlinearExpressionAnalysis: Sendable, Hashable {
    public let nodes: [NonlinearNodeAnalysis]
    public let output: Int
    public var outputAnalysis: NonlinearNodeAnalysis { nodes[output] }
}

/// An affine graph row: `lower <= coefficients · nodeValues <= upper`.
public struct AffineRelaxationRow: Sendable, Hashable {
    public let coefficients: [Double]
    public let lower: Double?
    public let upper: Double?
}

public struct GlobalExpressionRelaxation: Sendable, Hashable {
    public let analysis: NonlinearExpressionAnalysis
    public let rows: [AffineRelaxationRow]
    /// False means the relaxation remains valid, but at least one atom is
    /// represented only by its interval rather than a linking envelope.
    public let complete: Bool
}

public struct NonlinearConvexityCertificate: Sendable, Hashable {
    public let objective: NonlinearExpressionAnalysis
    public let constraints: [NonlinearExpressionAnalysis]
    public let globallyConvex: Bool
    public let finiteParameterBox: Bool
    public let relaxationComplete: Bool
}

public extension NonlinearExpression {
    func analyze(bounds: [ParameterBound]) throws -> NonlinearExpressionAnalysis {
        try validate(parameterCount: bounds.count)
        var result: [NonlinearNodeAnalysis] = []
        for node in nodes {
            let item: NonlinearNodeAnalysis
            switch node {
            case .constant(let value):
                item = .init(interval: interval(value, value), convexity: .constant)
            case .parameter(let index):
                item = .init(interval: interval(bounds[index].lower ?? -.infinity,
                                                bounds[index].upper ?? .infinity),
                             convexity: .affine)
            case .add(let a, let b): item = addAnalysis(result[a], result[b], subtract: false)
            case .subtract(let a, let b): item = addAnalysis(result[a], result[b], subtract: true)
            case .negate(let a):
                item = .init(interval: interval(-result[a].interval.upper,
                                                -result[a].interval.lower),
                             convexity: result[a].convexity.negated)
            case .multiply(let a, let b): item = multiplyAnalysis(result[a], result[b], same: a == b)
            case .divide(let a, let b): item = divideAnalysis(result[a], result[b])
            case .exp(let a): item = unaryAnalysis(result[a], .exp)
            case .log(let a): item = unaryAnalysis(result[a], .log)
            case .sqrt(let a): item = unaryAnalysis(result[a], .sqrt)
            case .sin(let a): item = unaryAnalysis(result[a], .sin)
            case .cos(let a): item = unaryAnalysis(result[a], .cos)
            case .pow(let a, let exponent): item = powerAnalysis(result[a], exponent)
            }
            result.append(item)
        }
        return .init(nodes: result, output: output)
    }

    func globalRelaxation(bounds: [ParameterBound]) throws -> GlobalExpressionRelaxation {
        let analysis = try analyze(bounds: bounds)
        let count = nodes.count
        var rows: [AffineRelaxationRow] = []
        var complete = true
        func coefficients(_ entries: (Int, Double)...) -> [Double] {
            var values = [Double](repeating: 0, count: count)
            for (index, value) in entries { values[index] += value }
            return values
        }
        func append(_ values: [Double], lower: Double? = nil, upper: Double? = nil) {
            rows.append(.init(coefficients: values, lower: lower, upper: upper))
        }
        for (index, node) in nodes.enumerated() {
            switch node {
            case .constant(let value): append(coefficients((index, 1)), lower: value, upper: value)
            case .parameter: break
            case .add(let a, let b): append(coefficients((index,1),(a,-1),(b,-1)), lower: 0, upper: 0)
            case .subtract(let a, let b): append(coefficients((index,1),(a,-1),(b,1)), lower: 0, upper: 0)
            case .negate(let a): append(coefficients((index,1),(a,1)), lower: 0, upper: 0)
            case .multiply(let a, let b):
                let x = analysis.nodes[a].interval, y = analysis.nodes[b].interval
                if x.isPoint { append(coefficients((index,1),(b,-x.lower)), lower: 0, upper: 0) }
                else if y.isPoint { append(coefficients((index,1),(a,-y.lower)), lower: 0, upper: 0) }
                else if x.isFinite && y.isFinite {
                    append(coefficients((index,1),(b,-x.lower),(a,-y.lower)), lower: -x.lower*y.lower)
                    append(coefficients((index,1),(b,-x.upper),(a,-y.upper)), lower: -x.upper*y.upper)
                    append(coefficients((index,1),(b,-x.upper),(a,-y.lower)), upper: -x.upper*y.lower)
                    append(coefficients((index,1),(b,-x.lower),(a,-y.upper)), upper: -x.lower*y.upper)
                } else { complete = false }
            case .divide(let a, let b) where analysis.nodes[b].interval.isPoint
                && analysis.nodes[b].interval.lower != 0:
                append(coefficients((index,1),(a,-1 / analysis.nodes[b].interval.lower)), lower: 0, upper: 0)
            case .exp(let a):
                complete = addUnaryEnvelope(&rows, count, index, a, analysis.nodes[a].interval, .exp, convex: true) && complete
            case .log(let a):
                complete = addUnaryEnvelope(&rows, count, index, a, analysis.nodes[a].interval, .log, convex: false) && complete
            case .sqrt(let a):
                complete = addUnaryEnvelope(&rows, count, index, a, analysis.nodes[a].interval, .sqrt, convex: false) && complete
            case .pow(let a, let exponent):
                if exponent == 0 { append(coefficients((index,1)), lower: 1, upper: 1) }
                else if exponent == 1 { append(coefficients((index,1),(a,-1)), lower: 0, upper: 0) }
                else {
                    let curvature = analysis.nodes[index].convexity
                    if curvature == .convex || curvature == .concave {
                        complete = addPowerEnvelope(&rows, count, index, a,
                            analysis.nodes[a].interval, exponent, convex: curvature == .convex) && complete
                    } else { complete = false }
                }
            default:
                if !analysis.nodes[index].interval.isPoint { complete = false }
            }
        }
        return .init(analysis: analysis, rows: rows, complete: complete)
    }
}

public extension NonlinearModel {
    func convexityCertificate(constraints: [NonlinearConstraint] = []) throws
        -> NonlinearConvexityCertificate {
        try validate()
        guard let objective else {
            throw NonlinearOptimizationError.invalidConfiguration(
                "convexity certification requires a scalar objective")
        }
        let objectiveAnalysis = try objective.analyze(bounds: bounds)
        let constraintAnalyses = try constraints.map { try $0.expression.analyze(bounds: bounds) }
        let constraintsConvex = zip(constraints, constraintAnalyses).allSatisfy { constraint, analysis in
            (constraint.bound.lower == nil || analysis.outputAnalysis.convexity.isConcave)
                && (constraint.bound.upper == nil || analysis.outputAnalysis.convexity.isConvex)
        }
        var relaxationComplete = try objective.globalRelaxation(bounds: bounds).complete
        for constraint in constraints {
            relaxationComplete = try constraint.expression.globalRelaxation(bounds: bounds).complete
                && relaxationComplete
        }
        return .init(objective: objectiveAnalysis, constraints: constraintAnalyses,
                     globallyConvex: objectiveAnalysis.outputAnalysis.convexity.isConvex
                        && constraintsConvex,
                     finiteParameterBox: bounds.allSatisfy { $0.lower != nil && $0.upper != nil },
                     relaxationComplete: relaxationComplete)
    }
}

private enum UnaryAtom { case exp, log, sqrt, sin, cos }
private func interval(_ lower: Double, _ upper: Double) -> NonlinearInterval {
    NonlinearInterval(lower: lower, upper: upper) ?? .whole
}
private func unaryValue(_ atom: UnaryAtom, _ x: Double) -> Double {
    switch atom { case .exp: Foundation.exp(x); case .log: Foundation.log(x)
    case .sqrt: Foundation.sqrt(x); case .sin: Foundation.sin(x); case .cos: Foundation.cos(x) }
}
private func unaryDerivative(_ atom: UnaryAtom, _ x: Double) -> Double {
    switch atom { case .exp: Foundation.exp(x); case .log: 1/x
    case .sqrt: 0.5/Foundation.sqrt(x); case .sin: Foundation.cos(x); case .cos: -Foundation.sin(x) }
}
private func unaryAnalysis(_ a: NonlinearNodeAnalysis, _ atom: UnaryAtom) -> NonlinearNodeAnalysis {
    let i = a.interval
    if i.isPoint {
        let value = unaryValue(atom, i.lower)
        return value.isFinite
            ? .init(interval: interval(value, value), convexity: .constant)
            : .init(interval: .whole, convexity: .unknown)
    }
    switch atom {
    case .exp: return .init(interval: interval(Foundation.exp(i.lower), Foundation.exp(i.upper)),
                            convexity: a.convexity.isConvex ? .convex : .unknown)
    case .log where i.lower > 0:
        return .init(interval: interval(Foundation.log(i.lower), Foundation.log(i.upper)),
                     convexity: a.convexity.isConcave ? .concave : .unknown)
    case .sqrt where i.lower >= 0:
        return .init(interval: interval(Foundation.sqrt(i.lower), Foundation.sqrt(i.upper)),
                     convexity: a.convexity.isConcave ? .concave : .unknown)
    case .sin, .cos:
        return .init(interval: interval(-1,1), convexity: i.isPoint ? .constant : .unknown)
    default: return .init(interval: .whole, convexity: .unknown)
    }
}
private func powerAnalysis(_ a: NonlinearNodeAnalysis, _ exponent: Double) -> NonlinearNodeAnalysis {
    if exponent == 0 { return .init(interval: interval(1,1), convexity: .constant) }
    if exponent == 1 { return a }
    let i = a.interval, integer = exponent.rounded() == exponent
    if i.isPoint {
        let value = Foundation.pow(i.lower, exponent)
        return value.isFinite ? .init(interval: interval(value,value), convexity: .constant)
                              : .init(interval: .whole, convexity: .unknown)
    }
    let range: NonlinearInterval
    if integer && exponent > 0 {
        let lo=Foundation.pow(i.lower,exponent), hi=Foundation.pow(i.upper,exponent)
        range = exponent.truncatingRemainder(dividingBy: 2) == 0 && i.lower <= 0 && i.upper >= 0
            ? interval(0,max(lo,hi)) : interval(min(lo,hi),max(lo,hi))
    } else if i.lower >= 0 && exponent > 0 {
        range=interval(Foundation.pow(i.lower,exponent),Foundation.pow(i.upper,exponent))
    } else { range = .whole }
    let curvature: ExpressionConvexity
    if (exponent == 2 || (integer && exponent >= 2 && exponent.truncatingRemainder(dividingBy: 2) == 0))
        && a.convexity == .affine { curvature = .convex }
    else if exponent > 1 && i.lower >= 0 && a.convexity.isConvex { curvature = .convex }
    else if exponent > 0 && exponent < 1 && i.lower >= 0 && a.convexity.isConcave { curvature = .concave }
    else { curvature = .unknown }
    return .init(interval: range, convexity: curvature)
}
private func addAnalysis(_ a: NonlinearNodeAnalysis, _ b: NonlinearNodeAnalysis,
                         subtract: Bool) -> NonlinearNodeAnalysis {
    let bc = subtract ? b.convexity.negated : b.convexity
    let range = subtract ? interval(a.interval.lower-b.interval.upper,a.interval.upper-b.interval.lower)
                         : interval(a.interval.lower+b.interval.lower,a.interval.upper+b.interval.upper)
    return .init(interval: range, convexity: combineCurvature(a.convexity,bc))
}
private func combineCurvature(_ a: ExpressionConvexity, _ b: ExpressionConvexity) -> ExpressionConvexity {
    if a == .constant { return b }; if b == .constant { return a }
    switch (a,b) { case (.affine,.affine): return .affine
    case (.affine,.convex),(.convex,.affine),(.convex,.convex): return .convex
    case (.affine,.concave),(.concave,.affine),(.concave,.concave): return .concave
    default: return .unknown }
}
private func multiplyAnalysis(_ a: NonlinearNodeAnalysis, _ b: NonlinearNodeAnalysis,
                              same: Bool) -> NonlinearNodeAnalysis {
    let range=multiplyInterval(a.interval,b.interval)
    if a.interval.isPoint { return .init(interval: range,convexity: scaleCurvature(b.convexity,a.interval.lower)) }
    if b.interval.isPoint { return .init(interval: range,convexity: scaleCurvature(a.convexity,b.interval.lower)) }
    return .init(interval: range,convexity: same && a.convexity == .affine ? .convex : .unknown)
}
private func divideAnalysis(_ a: NonlinearNodeAnalysis, _ b: NonlinearNodeAnalysis) -> NonlinearNodeAnalysis {
    if b.interval.isPoint && b.interval.lower != 0 {
        let k=1/b.interval.lower
        return .init(interval:multiplyInterval(a.interval,interval(k,k)),convexity:scaleCurvature(a.convexity,k))
    }
    if b.interval.lower <= 0 && b.interval.upper >= 0 { return .init(interval:.whole,convexity:.unknown) }
    let reciprocal=interval(min(1/b.interval.lower,1/b.interval.upper),max(1/b.interval.lower,1/b.interval.upper))
    return .init(interval:multiplyInterval(a.interval,reciprocal),convexity:.unknown)
}
private func multiplyInterval(_ a: NonlinearInterval, _ b: NonlinearInterval) -> NonlinearInterval {
    let values=[a.lower*b.lower,a.lower*b.upper,a.upper*b.lower,a.upper*b.upper]
    guard values.allSatisfy({ !$0.isNaN }) else { return .whole }
    return interval(values.min()!,values.max()!)
}
private func scaleCurvature(_ curvature: ExpressionConvexity, _ scale: Double) -> ExpressionConvexity {
    scale == 0 ? .constant : (scale < 0 ? curvature.negated : curvature)
}
private func addUnaryEnvelope(_ rows: inout [AffineRelaxationRow], _ count:Int, _ z:Int, _ x:Int,
                              _ i:NonlinearInterval, _ atom:UnaryAtom, convex:Bool)->Bool {
    guard !i.isPoint else{return true};guard i.isFinite else{return false}
    let fl=unaryValue(atom,i.lower),fu=unaryValue(atom,i.upper),m=(i.lower+i.upper)/2
    let fm=unaryValue(atom,m),d=unaryDerivative(atom,m)
    guard [fl,fu,fm,d].allSatisfy(\.isFinite) else{return false}
    return appendEnvelope(&rows,count,z,x,i,fl,fu,fm,d,convex)
}
private func addPowerEnvelope(_ rows:inout [AffineRelaxationRow],_ count:Int,_ z:Int,_ x:Int,
                              _ i:NonlinearInterval,_ p:Double,convex:Bool)->Bool {
    guard !i.isPoint else{return true};guard i.isFinite else{return false}
    let fl=Foundation.pow(i.lower,p),fu=Foundation.pow(i.upper,p),m=(i.lower+i.upper)/2
    let fm=Foundation.pow(m,p),d=p*Foundation.pow(m,p-1)
    guard [fl,fu,fm,d].allSatisfy(\.isFinite) else{return false}
    return appendEnvelope(&rows,count,z,x,i,fl,fu,fm,d,convex)
}
private func appendEnvelope(_ rows:inout [AffineRelaxationRow],_ count:Int,_ z:Int,_ x:Int,
                            _ i:NonlinearInterval,_ fl:Double,_ fu:Double,_ fm:Double,_ d:Double,
                            _ convex:Bool)->Bool {
    let slope=(fu-fl)/(i.upper-i.lower),intercept=fl-slope*i.lower,m=(i.lower+i.upper)/2,tangent=fm-d*m
    var sec=[Double](repeating:0,count:count);sec[z]=1;sec[x] = -slope
    var tan=[Double](repeating:0,count:count);tan[z]=1;tan[x] = -d
    if convex { rows.append(.init(coefficients:tan,lower:tangent,upper:nil));rows.append(.init(coefficients:sec,lower:nil,upper:intercept)) }
    else { rows.append(.init(coefficients:sec,lower:intercept,upper:nil));rows.append(.init(coefficients:tan,lower:nil,upper:tangent)) }
    return true
}
