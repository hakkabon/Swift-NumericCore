import Foundation

/// Options for the matrix-free Gauss–Newton/Levenberg–Marquardt solver.
public struct MatrixFreeLeastSquaresOptions: Sendable, Hashable {
    public var outer: NonlinearLeastSquaresOptions
    public var maxKrylovIterations: Int
    public var krylovTolerance: Double

    public init(outer: NonlinearLeastSquaresOptions = .init(), maxKrylovIterations: Int = 200,
                krylovTolerance: Double = 1e-6) {
        self.outer = outer; self.maxKrylovIterations = maxKrylovIterations
        self.krylovTolerance = krylovTolerance
    }
}

public struct MatrixFreeLeastSquaresResult: Sendable, Hashable {
    public let solution: NonlinearLeastSquaresResult
    public let krylovIterations: Int
    public let jacobianProducts: Int
    public let transposeJacobianProducts: Int
}

public extension NonlinearLeastSquares {
    /// Solves using only residual, `J·v`, and `Jᵀ·v` evaluations. Neither the
    /// Jacobian nor the Gauss–Newton matrix is assembled.
    static func solveMatrixFree(model: NonlinearModel, initial: [Double],
                                weights: [Double] = [], loss: RobustLoss = .squared,
                                options: MatrixFreeLeastSquaresOptions = .init()) throws
        -> MatrixFreeLeastSquaresResult {
        try model.validate()
        let outer = options.outer
        let lossScale: Double
        switch loss { case .squared: lossScale = 1; case .huber(let s), .cauchy(let s): lossScale = s }
        guard initial.count == model.parameterCount, !initial.isEmpty,
              initial.allSatisfy(\.isFinite), options.maxKrylovIterations > 0,
              options.krylovTolerance.isFinite, options.krylovTolerance > 0,
              outer.maxIterations > 0, outer.maxDampingIterations > 0,
              outer.gradientTolerance.isFinite, outer.gradientTolerance > 0,
              outer.stepTolerance.isFinite, outer.stepTolerance > 0,
              outer.costTolerance.isFinite, outer.costTolerance > 0,
              outer.initialDamping.isFinite, outer.initialDamping > 0,
              outer.dampingIncrease.isFinite, outer.dampingIncrease > 1,
              outer.dampingDecrease.isFinite,
              outer.dampingDecrease > 0, outer.dampingDecrease < 1 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid matrix-free least-squares options")
        }
        guard weights.isEmpty || (weights.count == model.residuals.count &&
              weights.allSatisfy { $0.isFinite && $0 >= 0 }),
              lossScale.isFinite, lossScale > 0 else {
            throw NonlinearOptimizationError.invalidConfiguration("weights must match residuals and be non-negative")
        }
        var point = zip(initial, model.bounds).map { project23($0, $1) }
        var residuals = try residualValues23(model, point)
        var evaluations = 1, damping = outer.initialDamping, accepted = 0, rejected = 0
        var krylov = 0, jProducts = 0, jtProducts = 0
        var cost = robustCost23(residuals, weights, loss)

        func finish(_ term: NonlinearTermination, _ iterations: Int, _ gradientNorm: Double)
            -> MatrixFreeLeastSquaresResult {
            .init(solution: .init(point: point, residuals: residuals, cost: cost,
                gradientNorm: gradientNorm, iterations: iterations, evaluations: evaluations,
                termination: term, finalDamping: damping, acceptedSteps: accepted,
                rejectedSteps: rejected), krylovIterations: krylov,
                jacobianProducts: jProducts, transposeJacobianProducts: jtProducts)
        }

        for iteration in 0..<outer.maxIterations {
            let scales = scales23(residuals, weights, loss)
            let weightedResidual = zip(residuals, scales).map { $0 * $1 * $1 }
            let gradient = try model.jacobianTransposeVectorProduct(parameters: point, weights: weightedResidual)
            jtProducts += 1
            let pg = projectedGradient23(point, gradient, model.bounds)
            let gradientNorm = pg.map(abs).max() ?? 0
            if gradientNorm <= outer.gradientTolerance { return finish(.convergedGradient, iteration, gradientNorm) }
            var acceptedCandidate: ([Double], [Double], Double, Double)?
            for _ in 0..<outer.maxDampingIterations {
                let rhs = gradient.map(-)
                let cg = try cg23(model, point, scales, damping, rhs,
                                  options.maxKrylovIterations, options.krylovTolerance)
                krylov += cg.iterations; jProducts += cg.jProducts; jtProducts += cg.jtProducts
                let candidate = zip(zip(point, cg.step), model.bounds).map { project23($0.0.0 + $0.0.1, $0.1) }
                let step = zip(candidate, point).map(-)
                if candidate.allSatisfy(\.isFinite), let next = try? residualValues23(model, candidate) {
                    evaluations += 1
                    let nextCost = robustCost23(next, weights, loss)
                    let js = try model.jacobianVectorProduct(parameters: point, direction: step); jProducts += 1
                    let quadratic = zip(js, scales).reduce(0.0) { $0 + ($1.0 * $1.1) * ($1.0 * $1.1) }
                    let predicted = -dot23(gradient, step) - 0.5 * quadratic
                    let ratio = predicted > 0 ? (cost - nextCost) / predicted : -.infinity
                    if ratio > 0, nextCost < cost {
                        acceptedCandidate = (candidate, next, nextCost, norm23(step)); accepted += 1
                        if ratio > 0.75 { damping = max(damping * outer.dampingDecrease, .leastNonzeroMagnitude) }
                        else if ratio < 0.25 { damping *= outer.dampingIncrease }
                        break
                    }
                }
                damping *= outer.dampingIncrease; rejected += 1
                if !damping.isFinite { break }
            }
            guard let next = acceptedCandidate else { return finish(.dampingLimit, iteration, gradientNorm) }
            let change = cost - next.2; point = next.0; residuals = next.1; cost = next.2
            if next.3 <= outer.stepTolerance * (1 + norm23(point)) {
                let g = try finalGradient23(model, point, residuals, weights, loss); jtProducts += 1
                return finish(.convergedStep, iteration + 1, projectedGradient23(point,g,model.bounds).map(abs).max() ?? 0)
            }
            if change <= outer.costTolerance * (1 + cost) {
                let g = try finalGradient23(model, point, residuals, weights, loss); jtProducts += 1
                return finish(.convergedObjective, iteration + 1, projectedGradient23(point,g,model.bounds).map(abs).max() ?? 0)
            }
        }
        let g = try finalGradient23(model, point, residuals, weights, loss); jtProducts += 1
        return finish(.iterationLimit, outer.maxIterations, projectedGradient23(point,g,model.bounds).map(abs).max() ?? 0)
    }
}

private func cg23(_ model: NonlinearModel, _ x: [Double], _ scales: [Double], _ damping: Double,
                  _ b: [Double], _ maxIterations: Int, _ tolerance: Double) throws
    -> (step: [Double], iterations: Int, jProducts: Int, jtProducts: Int) {
    var step = [Double](repeating: 0, count: b.count), r = b, p = b
    var rr = dot23(r,r); let target = tolerance * max(norm23(b), 1)
    if sqrt(rr) <= target { return (step,0,0,0) }
    for k in 0..<maxIterations {
        let j = try model.jacobianVectorProduct(parameters: x, direction: p)
        let weighted = zip(j,scales).map { $0 * $1 * $1 }
        var ap = try model.jacobianTransposeVectorProduct(parameters: x, weights: weighted)
        for i in ap.indices { ap[i] += damping * p[i] }
        let denominator = dot23(p,ap)
        if !denominator.isFinite || denominator <= 0 { return (step,k+1,k+1,k+1) }
        let alpha = rr / denominator
        for i in step.indices { step[i] += alpha*p[i]; r[i] -= alpha*ap[i] }
        let next = dot23(r,r)
        if sqrt(next) <= target { return (step,k+1,k+1,k+1) }
        let beta = next/rr; for i in p.indices { p[i] = r[i] + beta*p[i] }; rr=next
    }
    return (step,maxIterations,maxIterations,maxIterations)
}
private func residualValues23(_ m:NonlinearModel,_ x:[Double])throws->[Double]{try m.residuals.map{try $0.evaluateDirectional(parameters:x,direction:[Double](repeating:0,count:x.count)).value}}
private func finalGradient23(_ m:NonlinearModel,_ x:[Double],_ r:[Double],_ w:[Double],_ l:RobustLoss)throws->[Double]{let s=scales23(r,w,l);return try m.jacobianTransposeVectorProduct(parameters:x,weights:zip(r,s).map{$0*$1*$1})}
private func scales23(_ r:[Double],_ w:[Double],_ loss:RobustLoss)->[Double]{r.indices.map{i in let rw:Double;switch loss{case .squared:rw=1;case .huber(let s):rw=abs(r[i])<=s||r[i]==0 ? 1:s/abs(r[i]);case .cauchy(let s):rw=1/(1+(r[i]/s)*(r[i]/s))};return sqrt((w.isEmpty ? 1:w[i])*rw)}}
private func robustCost23(_ r:[Double],_ w:[Double],_ loss:RobustLoss)->Double{r.indices.reduce(0){sum,i in let v=r[i],rho:Double;switch loss{case .squared:rho=0.5*v*v;case .huber(let s):rho=abs(v)<=s ? 0.5*v*v:s*(abs(v)-0.5*s);case .cauchy(let s):rho=0.5*s*s*log(1+(v/s)*(v/s))};return sum+(w.isEmpty ? 1:w[i])*rho}}
private func project23(_ x:Double,_ b:ParameterBound)->Double{min(max(x,b.lower ?? -.infinity),b.upper ?? .infinity)}
private func projectedGradient23(_ x:[Double],_ g:[Double],_ b:[ParameterBound])->[Double]{
    x.indices.map { i in
        let atLower = b[i].lower.map { x[i] <= $0 } ?? false
        let atUpper = b[i].upper.map { x[i] >= $0 } ?? false
        return (atLower && g[i] > 0) || (atUpper && g[i] < 0) ? 0 : g[i]
    }
}
private func dot23(_ a:[Double],_ b:[Double])->Double{zip(a,b).reduce(0){$0+$1.0*$1.1}}
private func norm23(_ x:[Double])->Double{sqrt(dot23(x,x))}
