import Foundation

public struct TimePoint: Sendable, Hashable {
    public let time: Double
    public let state: [Double]
    public let derivative: [Double]
}

public enum EventDirection: Sendable, Hashable { case any, rising, falling }

public struct TimeEventSpecification: Sendable, Hashable {
    public let direction: EventDirection
    public let terminal: Bool
    public init(direction: EventDirection = .any, terminal: Bool = false) {
        self.direction = direction; self.terminal = terminal
    }
}

public struct TimeEvent: Sendable, Hashable {
    public let index: Int
    public let time: Double
    public let state: [Double]
    public let value: Double
    public let terminal: Bool
}

public enum TimeIntegrationTermination: Sendable, Hashable {
    case reachedEnd, terminalEvent, stepLimit, stepSizeUnderflow, newtonFailure, cancelled
}

public struct TimeIntegrationOptions: Sendable, Hashable {
    public var absoluteTolerance: Double
    public var relativeTolerance: Double
    public var initialStep: Double
    public var minimumStep: Double
    public var maximumStep: Double
    public var maxSteps: Int
    public var maxRejectedSteps: Int
    public var maxNewtonIterations: Int
    public var newtonTolerance: Double

    public init(absoluteTolerance: Double = 1e-8, relativeTolerance: Double = 1e-6,
                initialStep: Double = 1e-3, minimumStep: Double = 1e-12,
                maximumStep: Double = 0.1, maxSteps: Int = 100_000,
                maxRejectedSteps: Int = 10_000, maxNewtonIterations: Int = 12,
                newtonTolerance: Double = 1e-10) {
        self.absoluteTolerance = absoluteTolerance; self.relativeTolerance = relativeTolerance
        self.initialStep = initialStep; self.minimumStep = minimumStep
        self.maximumStep = maximumStep; self.maxSteps = maxSteps
        self.maxRejectedSteps = maxRejectedSteps; self.maxNewtonIterations = maxNewtonIterations
        self.newtonTolerance = newtonTolerance
    }
}

public struct TimeIntegrationIteration: Sendable, Hashable {
    public let acceptedSteps: Int
    public let rejectedSteps: Int
    public let time: Double
    public let step: Double
    public let errorNorm: Double
    public let newtonIterations: Int
}

public struct TimeIntegrationResult: Sendable, Hashable {
    public let points: [TimePoint]
    public let events: [TimeEvent]
    public let acceptedSteps: Int
    public let rejectedSteps: Int
    public let evaluations: Int
    public let jacobianEvaluations: Int
    public let newtonIterations: Int
    public let termination: TimeIntegrationTermination

    /// Piecewise cubic Hermite interpolation over accepted steps.
    public func state(at time: Double) -> [Double]? {
        guard let first = points.first, let last = points.last else { return nil }
        let increasing = last.time >= first.time
        guard increasing ? (time >= first.time && time <= last.time)
                         : (time <= first.time && time >= last.time) else { return nil }
        if time == last.time { return last.state }
        guard let index = points.indices.dropLast().first(where: {
            increasing ? time >= points[$0].time && time <= points[$0 + 1].time
                       : time <= points[$0].time && time >= points[$0 + 1].time
        }) else { return nil }
        return tiHermite(points[index], points[index + 1], time)
    }
}

public struct DAEEvaluation: Sendable, Hashable {
    public let residuals: [Double]
    public let jacobianState: [[Double]]
    public let jacobianDerivative: [[Double]]
    public init(residuals: [Double], jacobianState: [[Double]], jacobianDerivative: [[Double]]) {
        self.residuals = residuals; self.jacobianState = jacobianState
        self.jacobianDerivative = jacobianDerivative
    }

    /// Builds `F = M*yDot - f(t,y)`. The mass matrix may be singular.
    public static func massMatrix(
        _ massMatrix: [[Double]], rightHandSide: [Double],
        rightHandSideJacobian: [[Double]], derivative: [Double]
    ) -> Self {
        let residuals = massMatrix.enumerated().map { row, values in
            zip(values, derivative).reduce(0) { $0 + $1.0 * $1.1 }
                - (row < rightHandSide.count ? rightHandSide[row] : .nan)
        }
        return .init(residuals: residuals,
                     jacobianState: rightHandSideJacobian.map { $0.map(-) },
                     jacobianDerivative: massMatrix)
    }
}

public enum TimeIntegrator {
    public typealias ODERightHandSide = (_ time: Double, _ state: [Double]) throws -> [Double]
    public typealias EventFunction = (_ time: Double, _ state: [Double]) throws -> [Double]
    public typealias DAESystem = (_ time: Double, _ state: [Double], _ derivative: [Double]) throws -> DAEEvaluation
    public typealias Observer = (TimeIntegrationIteration) -> Bool

    /// Adaptive Dormand–Prince 5(4), with optional directional events.
    public static func integrate(
        from start: Double, to end: Double, initialState: [Double],
        options: TimeIntegrationOptions = .init(), events specifications: [TimeEventSpecification] = [],
        eventFunction: EventFunction? = nil, observer: Observer? = nil,
        rightHandSide: ODERightHandSide
    ) throws -> TimeIntegrationResult {
        try tiValidate(start, end, initialState, options)
        guard specifications.isEmpty == (eventFunction == nil) else {
            throw tiInvalid("event specifications and function must be provided together")
        }
        let direction = end >= start ? 1.0 : -1.0
        var time = start, state = initialState, evaluations = 0
        var derivative = try tiVector(rightHandSide(time, state), count: state.count); evaluations += 1
        var previousEvents = try tiEvents(eventFunction?(time, state) ?? [], count: specifications.count)
        var step = direction * min(options.initialStep, options.maximumStep)
        var points = [TimePoint(time: time, state: state, derivative: derivative)]
        var foundEvents: [TimeEvent] = []; var accepted = 0, rejected = 0
        while !tiReached(time, end, direction) {
            if accepted >= options.maxSteps { return tiResult(points, foundEvents, accepted, rejected, evaluations, 0, 0, .stepLimit) }
            if rejected > options.maxRejectedSteps { return tiResult(points, foundEvents, accepted, rejected, evaluations, 0, 0, .stepSizeUnderflow) }
            step = direction * min(abs(step), abs(end - time), options.maximumStep)
            if abs(step) < options.minimumStep { return tiResult(points, foundEvents, accepted, rejected, evaluations, 0, 0, .stepSizeUnderflow) }
            let trial = try tiRK45(time, state, derivative, step, rightHandSide); evaluations += 6
            let error = tiScaledError(trial.high, trial.low, state, options)
            if error <= 1 {
                let nextTime = time + step
                let nextEvents = try tiEvents(eventFunction?(nextTime, trial.high) ?? [], count: specifications.count)
                let nextPoint = TimePoint(time: nextTime, state: trial.high, derivative: trial.derivative)
                let prior = points.last!
                for index in specifications.indices where tiCrossed(previousEvents[index], nextEvents[index], specifications[index].direction) {
                    let located = try tiLocateEvent(prior, nextPoint, index, previousEvents[index], nextEvents[index], eventFunction!)
                    foundEvents.append(.init(index: index, time: located.time, state: located.state,
                                             value: located.value, terminal: specifications[index].terminal))
                    if specifications[index].terminal {
                        let rootDerivative = try tiVector(rightHandSide(located.time, located.state), count: state.count); evaluations += 1
                        points.append(.init(time: located.time, state: located.state, derivative: rootDerivative))
                        return tiResult(points, foundEvents, accepted + 1, rejected, evaluations, 0, 0, .terminalEvent)
                    }
                }
                time = nextTime; state = trial.high; derivative = trial.derivative
                points.append(nextPoint); previousEvents = nextEvents; accepted += 1
                if observer?(.init(acceptedSteps: accepted, rejectedSteps: rejected, time: time,
                                   step: step, errorNorm: error, newtonIterations: 0)) == false {
                    return tiResult(points, foundEvents, accepted, rejected, evaluations, 0, 0, .cancelled)
                }
                step *= tiFactor(error, order: 5)
            } else { rejected += 1; step *= min(tiFactor(error, order: 5), 0.9) }
        }
        return tiResult(points, foundEvents, accepted, rejected, evaluations, 0, 0, .reachedEnd)
    }

    /// Adaptive backward Euler for residual-form index-1 DAEs
    /// `F(t, y, yDot) = 0`, using analytic `F_y` and `F_yDot`.
    public static func integrateDAE(
        from start: Double, to end: Double, initialState: [Double],
        initialDerivative: [Double], options: TimeIntegrationOptions = .init(),
        observer: Observer? = nil, system: DAESystem
    ) throws -> TimeIntegrationResult {
        try tiValidate(start, end, initialState, options)
        guard initialDerivative.count == initialState.count, initialDerivative.allSatisfy(\.isFinite) else { throw tiInvalid("invalid initial DAE derivative") }
        let initial = try tiDAE(system(start, initialState, initialDerivative), count: initialState.count)
        guard tiInfNorm(initial.residuals) <= max(options.newtonTolerance, options.absoluteTolerance) else { throw tiInvalid("inconsistent initial DAE state and derivative") }
        let direction = end >= start ? 1.0 : -1.0
        var time = start, state = initialState, derivative = initialDerivative
        var step = direction * min(options.initialStep, options.maximumStep)
        var points = [TimePoint(time: time, state: state, derivative: derivative)]
        var accepted = 0, rejected = 0, evaluations = 1, jacobians = 1, newtonTotal = 0
        while !tiReached(time, end, direction) {
            if accepted >= options.maxSteps { return tiResult(points, [], accepted, rejected, evaluations, jacobians, newtonTotal, .stepLimit) }
            step = direction * min(abs(step), abs(end - time), options.maximumStep)
            if abs(step) < options.minimumStep || rejected > options.maxRejectedSteps { return tiResult(points, [], accepted, rejected, evaluations, jacobians, newtonTotal, .stepSizeUnderflow) }
            let full = try tiDAEStep(time, state, derivative, step, options, system)
            let half1 = try tiDAEStep(time, state, derivative, 0.5 * step, options, system)
            let half2 = try tiDAEStep(time + 0.5 * step, half1.state, half1.derivative, 0.5 * step, options, system)
            for item in [full, half1, half2] { evaluations += item.evaluations; jacobians += item.jacobians; newtonTotal += item.iterations }
            guard full.converged, half1.converged, half2.converged else {
                rejected += 1; step *= 0.5
                if abs(step) < options.minimumStep { return tiResult(points, [], accepted, rejected, evaluations, jacobians, newtonTotal, .newtonFailure) }
                continue
            }
            let error = tiScaledError(half2.state, full.state, state, options)
            if error <= 1 {
                time += step; state = half2.state; derivative = half2.derivative; accepted += 1
                points.append(.init(time: time, state: state, derivative: derivative))
                if observer?(.init(acceptedSteps: accepted, rejectedSteps: rejected, time: time, step: step,
                                   errorNorm: error, newtonIterations: full.iterations + half1.iterations + half2.iterations)) == false {
                    return tiResult(points, [], accepted, rejected, evaluations, jacobians, newtonTotal, .cancelled)
                }
                step *= tiFactor(error, order: 2)
            } else { rejected += 1; step *= min(tiFactor(error, order: 2), 0.9) }
        }
        return tiResult(points, [], accepted, rejected, evaluations, jacobians, newtonTotal, .reachedEnd)
    }
}

private struct TIRKTrial { let high: [Double]; let low: [Double]; let derivative: [Double] }
private func tiRK45(_ t: Double, _ y: [Double], _ k1: [Double], _ h: Double,
                    _ rhs: TimeIntegrator.ODERightHandSide) throws -> TIRKTrial {
    func stage(_ terms: [(Double, [Double])]) -> [Double] { y.indices.map { i in y[i] + h * terms.reduce(0) { $0 + $1.0 * $1.1[i] } } }
    let k2 = try tiVector(rhs(t + h/5, stage([(1.0/5, k1)])), count: y.count)
    let k3 = try tiVector(rhs(t + 3*h/10, stage([(3.0/40, k1), (9.0/40, k2)])), count: y.count)
    let k4 = try tiVector(rhs(t + 4*h/5, stage([(44.0/45, k1), (-56.0/15, k2), (32.0/9, k3)])), count: y.count)
    let k5 = try tiVector(rhs(t + 8*h/9, stage([(19372.0/6561, k1), (-25360.0/2187, k2), (64448.0/6561, k3), (-212.0/729, k4)])), count: y.count)
    let k6 = try tiVector(rhs(t + h, stage([(9017.0/3168, k1), (-355.0/33, k2), (46732.0/5247, k3), (49.0/176, k4), (-5103.0/18656, k5)])), count: y.count)
    let high = stage([(35.0/384, k1), (500.0/1113, k3), (125.0/192, k4), (-2187.0/6784, k5), (11.0/84, k6)])
    let k7 = try tiVector(rhs(t + h, high), count: y.count)
    let low = stage([(5179.0/57600, k1), (7571.0/16695, k3), (393.0/640, k4), (-92097.0/339200, k5), (187.0/2100, k6), (1.0/40, k7)])
    return .init(high: high, low: low, derivative: k7)
}

private struct TIDAEStep { let state: [Double]; let derivative: [Double]; let iterations: Int; let evaluations: Int; let jacobians: Int; let converged: Bool }
private func tiDAEStep(_ time: Double, _ old: [Double], _ oldDerivative: [Double], _ step: Double,
                       _ options: TimeIntegrationOptions, _ system: TimeIntegrator.DAESystem) throws -> TIDAEStep {
    var state = zip(old, oldDerivative).map { $0 + step * $1 }
    for iteration in 0..<options.maxNewtonIterations {
        let derivative = zip(state, old).map { ($0 - $1) / step }
        let evaluation = try tiDAE(system(time + step, state, derivative), count: old.count)
        if tiInfNorm(evaluation.residuals) <= options.newtonTolerance { return .init(state: state, derivative: derivative, iterations: iteration, evaluations: iteration + 1, jacobians: iteration + 1, converged: true) }
        let matrix = old.indices.map { i in old.indices.map { j in evaluation.jacobianState[i][j] + evaluation.jacobianDerivative[i][j] / step } }
        guard let delta = tiDenseSolve(matrix, evaluation.residuals.map(-)) else { return .init(state: state, derivative: derivative, iterations: iteration + 1, evaluations: iteration + 1, jacobians: iteration + 1, converged: false) }
        for index in state.indices { state[index] += delta[index] }
    }
    return .init(state: state, derivative: zip(state, old).map { ($0 - $1) / step }, iterations: options.maxNewtonIterations, evaluations: options.maxNewtonIterations, jacobians: options.maxNewtonIterations, converged: false)
}

private func tiLocateEvent(_ left: TimePoint, _ right: TimePoint, _ index: Int, _ leftValue: Double, _ rightValue: Double, _ event: TimeIntegrator.EventFunction) throws -> (time: Double, state: [Double], value: Double) { var a = left.time, b = right.time, lv = leftValue, rv = rightValue; for _ in 0..<50 { let mid = 0.5 * (a + b), state = tiHermite(left, right, mid), values = try event(mid, state); guard index < values.count, values[index].isFinite else { throw tiInvalid("invalid event evaluation") }; let value = values[index]; if value == 0 || abs(b-a) <= 1e-12 * (1 + abs(mid)) { return (mid, state, value) }; if (lv <= 0 && value >= 0) || (lv >= 0 && value <= 0) { b = mid; rv = value } else { a = mid; lv = value } }; let time = 0.5 * (a+b); return (time, tiHermite(left, right, time), 0.5 * (lv+rv)) }
private func tiHermite(_ a: TimePoint, _ b: TimePoint, _ time: Double) -> [Double] { let h = b.time-a.time; if h == 0 { return a.state }; let s=(time-a.time)/h, h00=2*pow(s,3)-3*pow(s,2)+1, h10=pow(s,3)-2*pow(s,2)+s, h01 = -2*pow(s,3)+3*pow(s,2), h11=pow(s,3)-pow(s,2); return a.state.indices.map { h00*a.state[$0]+h10*h*a.derivative[$0]+h01*b.state[$0]+h11*h*b.derivative[$0] } }
private func tiCrossed(_ a: Double, _ b: Double, _ direction: EventDirection) -> Bool { switch direction { case .any: return (a < 0 && b >= 0)||(a > 0 && b <= 0); case .rising: return a < 0 && b >= 0; case .falling: return a > 0 && b <= 0 } }
private func tiReached(_ time: Double, _ end: Double, _ direction: Double) -> Bool { direction * (end-time) <= 16 * Double.ulpOfOne * (1+abs(end)) }
private func tiFactor(_ error: Double, order: Double) -> Double { error == 0 ? 5 : min(5, max(0.2, 0.9 * pow(error, -1/order))) }
private func tiScaledError(_ high: [Double], _ low: [Double], _ old: [Double], _ options: TimeIntegrationOptions) -> Double { sqrt(high.indices.reduce(0) { sum, i in let scale=options.absoluteTolerance+options.relativeTolerance*max(abs(old[i]),abs(high[i])); return sum+pow((high[i]-low[i])/scale,2) } / Double(max(high.count,1))) }
private func tiValidate(_ start: Double, _ end: Double, _ initial: [Double], _ o: TimeIntegrationOptions) throws { guard start.isFinite, end.isFinite, !initial.isEmpty, initial.allSatisfy(\.isFinite), o.absoluteTolerance.isFinite, o.absoluteTolerance > 0, o.relativeTolerance.isFinite, o.relativeTolerance >= 0, o.initialStep.isFinite, o.initialStep > 0, o.minimumStep.isFinite, o.minimumStep > 0, o.maximumStep.isFinite, o.maximumStep >= o.minimumStep, o.maxSteps > 0, o.maxNewtonIterations > 0, o.newtonTolerance.isFinite, o.newtonTolerance > 0 else { throw tiInvalid("invalid time integration configuration") } }
private func tiVector(_ values: [Double], count: Int) throws -> [Double] { guard values.count == count, values.allSatisfy(\.isFinite) else { throw tiInvalid("invalid differential equation evaluation") }; return values }
private func tiEvents(_ values: [Double], count: Int) throws -> [Double] { guard values.count == count, values.allSatisfy(\.isFinite) else { throw tiInvalid("invalid event evaluation") }; return values }
private func tiDAE(_ value: DAEEvaluation, count: Int) throws -> DAEEvaluation { func matrix(_ rows:[[Double]]) -> Bool { rows.count == count && rows.allSatisfy { $0.count == count && $0.allSatisfy(\.isFinite) } }; guard value.residuals.count == count, value.residuals.allSatisfy(\.isFinite), matrix(value.jacobianState), matrix(value.jacobianDerivative) else { throw tiInvalid("invalid DAE evaluation") }; return value }
private func tiInfNorm(_ values: [Double]) -> Double { values.map(abs).max() ?? 0 }
private func tiDenseSolve(_ input: [[Double]], _ right: [Double]) -> [Double]? { var a=input,b=right; for k in b.indices { let pivot=(k..<b.count).max { abs(a[$0][k]) < abs(a[$1][k]) }!; if abs(a[pivot][k]) <= 1e-14{return nil};a.swapAt(k,pivot);b.swapAt(k,pivot);if k+1<b.count{for i in k+1..<b.count{let f=a[i][k]/a[k][k];for j in k..<b.count{a[i][j]-=f*a[k][j]};b[i]-=f*b[k]}}};for i in b.indices.reversed(){if i+1<b.count{for j in i+1..<b.count{b[i]-=a[i][j]*b[j]}};b[i]/=a[i][i]};return b }
private func tiResult(_ points:[TimePoint],_ events:[TimeEvent],_ accepted:Int,_ rejected:Int,_ evaluations:Int,_ jacobians:Int,_ newton:Int,_ termination:TimeIntegrationTermination)->TimeIntegrationResult{.init(points:points,events:events,acceptedSteps:accepted,rejectedSteps:rejected,evaluations:evaluations,jacobianEvaluations:jacobians,newtonIterations:newton,termination:termination)}
private func tiInvalid(_ message: String) -> NonlinearOptimizationError { .invalidEvaluation(message) }
