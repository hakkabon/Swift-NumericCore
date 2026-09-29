import Foundation

/// Independent lower and upper bounds for a nonlinear parameter.
public struct ParameterBound: Sendable, Hashable {
    public var lower: Double?
    public var upper: Double?
    public init(lower: Double? = nil, upper: Double? = nil) {
        self.lower = lower; self.upper = upper
    }
    public static let free = ParameterBound()
    public static func fixed(_ value: Double) -> ParameterBound { .init(lower: value, upper: value) }
}

public enum RobustLoss: Sendable, Hashable {
    case squared
    case huber(scale: Double)
    case cauchy(scale: Double)
}

/// Projected limited-memory BFGS for smooth box-constrained objectives.
public enum LBFGSB {
    public typealias Objective = LBFGS.Objective
    public typealias Observer = LBFGS.Observer

    public static func minimize(initial: [Double], bounds: [ParameterBound],
                                options: LBFGSOptions = .init(), observer: Observer? = nil,
                                objective: Objective) throws -> LBFGSResult {
        try validate(initial, bounds, options)
        var point = zip(initial, bounds).map(project)
        var current = try checked(objective, point)
        var evaluations = 1
        var ss: [[Double]] = [], ys: [[Double]] = [], rhos: [Double] = []
        var lastStep: Double?
        for iteration in 0..<options.maxIterations {
            let pg = projectedGradient(point, current.1, bounds)
            if inf8(pg) <= options.gradientTolerance {
                return makeResult(point, current, iteration, evaluations, .convergedGradient,
                                  lastStep, ss.count, inf8(pg))
            }
            var direction = twoLoop8(pg, ss, ys, rhos)
            feasibleDirection(point, bounds, &direction)
            if !direction.allSatisfy({ $0.isFinite }) || dot8(pg, direction) >= 0 {
                ss.removeAll(); ys.removeAll(); rhos.removeAll()
                direction = pg.map(-); feasibleDirection(point, bounds, &direction)
            }
            var alpha = 1.0
            var accepted: ([Double], (Double, [Double]), [Double], Double)?
            for _ in 0..<options.maxLineSearchIterations {
                let candidate = zip(zip(point, direction), bounds).map { item -> Double in
                    let ((x, d), bound) = item
                    return project((x + alpha * d, bound))
                }
                let displacement = zip(candidate, point).map(-)
                let slope = dot8(current.1, displacement)
                if norm8(displacement) > 0, slope < 0 {
                    evaluations += 1
                    if let next = try? checked(objective, candidate),
                       next.0 <= current.0 + options.armijo * slope {
                        accepted = (candidate, next, displacement, alpha); break
                    }
                }
                alpha *= options.backtracking
            }
            guard let (nextPoint, next, s, acceptedAlpha) = accepted else {
                return makeResult(point, current, iteration, evaluations, .lineSearchFailed,
                                  lastStep, ss.count, inf8(projectedGradient(point, current.1, bounds)))
            }
            let y = zip(next.1, current.1).map(-), curvature = dot8(s, y)
            if curvature > 1e-12 * norm8(s) * norm8(y) {
                if ss.count == options.historySize { ss.removeFirst(); ys.removeFirst(); rhos.removeFirst() }
                ss.append(s); ys.append(y); rhos.append(1 / curvature)
            }
            let stepNorm = norm8(s), objectiveChange = abs(current.0 - next.0)
            point = nextPoint; current = next; lastStep = acceptedAlpha
            let pgNorm = inf8(projectedGradient(point, current.1, bounds))
            if observer?(.init(iteration: iteration + 1, objective: current.0,
                               gradientNorm: pgNorm, step: acceptedAlpha, evaluations: evaluations)) == false {
                return makeResult(point, current, iteration + 1, evaluations, .cancelled, lastStep, ss.count, pgNorm)
            }
            if stepNorm <= options.stepTolerance * (1 + norm8(point)) {
                return makeResult(point, current, iteration + 1, evaluations, .convergedStep, lastStep, ss.count, pgNorm)
            }
            if objectiveChange <= options.objectiveTolerance * (1 + abs(current.0)) {
                return makeResult(point, current, iteration + 1, evaluations, .convergedObjective, lastStep, ss.count, pgNorm)
            }
        }
        let pgNorm = inf8(projectedGradient(point, current.1, bounds))
        return makeResult(point, current, options.maxIterations, evaluations, .iterationLimit,
                          lastStep, ss.count, pgNorm)
    }

    private static func validate(_ x: [Double], _ b: [ParameterBound], _ o: LBFGSOptions) throws {
        guard !x.isEmpty, x.count == b.count, x.allSatisfy(\.isFinite), o.maxIterations > 0,
              o.historySize > 0, o.maxLineSearchIterations > 0, o.gradientTolerance > 0,
              o.stepTolerance > 0, o.objectiveTolerance > 0, o.armijo > 0,
              o.armijo < o.wolfe, o.wolfe < 1, o.backtracking > 0, o.backtracking < 1,
              b.allSatisfy(validBound) else { throw NonlinearOptimizationError.invalidConfiguration("invalid bounded L-BFGS problem or options") }
    }
    private static func checked(_ f: Objective, _ x: [Double]) throws -> (Double, [Double]) {
        let v = try f(x); guard v.value.isFinite, v.gradient.count == x.count,
            v.gradient.allSatisfy(\.isFinite) else { throw NonlinearOptimizationError.invalidEvaluation("objective must return a finite value and matching finite gradient") }; return v
    }
    private static func projectedGradient(_ x:[Double],_ g:[Double],_ b:[ParameterBound])->[Double]{zip(zip(x,g),b).map{let((x,g),b)=$0;return ((b.lower.map{x <= $0} ?? false)&&g>0)||((b.upper.map{x >= $0} ?? false)&&g<0) ? 0:g}}
    private static func feasibleDirection(_ x:[Double],_ b:[ParameterBound],_ d:inout[Double]){for i in d.indices{if ((b[i].lower.map{x[i] <= $0} ?? false)&&d[i]<0)||((b[i].upper.map{x[i] >= $0} ?? false)&&d[i]>0){d[i]=0}}}
    private static func twoLoop8(_ g:[Double],_ ss:[[Double]],_ ys:[[Double]],_ rhos:[Double])->[Double]{var q=g,a=[Double](repeating:0,count:ss.count);for i in ss.indices.reversed(){a[i]=rhos[i]*dot8(ss[i],q);q=zip(q,ys[i]).map{$0-a[i]*$1}};if let s=ss.last,let y=ys.last{let z=dot8(s,y)/dot8(y,y);q=q.map{z*$0}};for i in ss.indices{let beta=rhos[i]*dot8(ys[i],q);q=zip(q,ss[i]).map{$0+(a[i]-beta)*$1}};return q.map(-)}
    private static func makeResult(_ x:[Double],_ e:(Double,[Double]),_ i:Int,_ n:Int,_ t:NonlinearTermination,_ a:Double?,_ c:Int,_ pg:Double)->LBFGSResult{.init(point:x,objective:e.0,gradient:e.1,iterations:i,evaluations:n,termination:t,gradientNorm:pg,acceptedStep:a,storedCurvaturePairs:c)}
}

public extension NonlinearLeastSquares {
    /// Weighted robust Levenberg-Marquardt with box-constrained parameters.
    static func solve(initial: [Double], bounds: [ParameterBound], weights: [Double] = [],
                      loss: RobustLoss = .squared,
                      options: NonlinearLeastSquaresOptions = .init(), observer: Observer? = nil,
                      model: Model) throws -> NonlinearLeastSquaresResult {
        guard !initial.isEmpty, initial.count == bounds.count, initial.allSatisfy(\.isFinite),
              bounds.allSatisfy(validBound), validLoss(loss), options.maxIterations > 0,
              options.maxDampingIterations > 0, options.gradientTolerance.isFinite,
              options.gradientTolerance > 0, options.stepTolerance.isFinite,
              options.stepTolerance > 0, options.costTolerance.isFinite,
              options.costTolerance > 0, options.initialDamping.isFinite,
              options.initialDamping > 0, options.dampingIncrease.isFinite,
              options.dampingIncrease > 1, options.dampingDecrease.isFinite,
              options.dampingDecrease > 0, options.dampingDecrease < 1 else { throw NonlinearOptimizationError.invalidConfiguration("invalid robust least-squares configuration") }
        var point = zip(initial,bounds).map(project), value = try checkedModel8(model, point)
        guard weights.isEmpty || (weights.count == value.residuals.count && weights.allSatisfy{$0.isFinite && $0 >= 0}) else { throw NonlinearOptimizationError.invalidConfiguration("weights must match residuals and be finite and non-negative") }
        let residualCount = value.residuals.count
        var evaluations=1, damping=options.initialDamping, acceptedSteps=0, rejectedSteps=0
        var cost=robustCost8(value.residuals,weights,loss)
        func finish(_ i:Int,_ t:NonlinearTermination,_ g:Double)->NonlinearLeastSquaresResult{.init(point:point,residuals:value.residuals,cost:cost,gradientNorm:g,iterations:i,evaluations:evaluations,termination:t,finalDamping:damping,acceptedSteps:acceptedSteps,rejectedSteps:rejectedSteps)}
        for iteration in 0..<options.maxIterations {
            let scaled=scaled8(value,weights,loss), equations=normal8(scaled,point.count), gnorm=inf8(projectedGradient8(point,equations.1,bounds))
            if gnorm <= options.gradientTolerance { return finish(iteration,.convergedGradient,gnorm) }
            var accepted:([Double],NonlinearLeastSquaresEvaluation,Double,Double)?
            for _ in 0..<options.maxDampingIterations {
                var a=scaled.jacobian, rhs=scaled.residuals.map(-)
                for i in point.indices { var row=[Double](repeating:0,count:point.count);row[i]=sqrt(damping*max(abs(equations.0[i][i]),1));a.append(row);rhs.append(0) }
                if let rawStep=qr8(a,rhs,1e-12) {
                    let candidate=zip(zip(point,rawStep),bounds).map{project(($0.0.0+$0.0.1,$0.1))}, step=zip(candidate,point).map(-)
                    evaluations += 1
                    if let next=try? checkedModel8(model,candidate), next.residuals.count == residualCount {
                        let nextCost=robustCost8(next.residuals,weights,loss), predicted=predicted8(equations.1,equations.0,step), ratio=predicted > 0 ? (cost-nextCost)/predicted : -.infinity
                        if ratio > 0 && nextCost < cost { accepted=(candidate,next,nextCost,norm8(step));if ratio>0.75{damping=max(damping*options.dampingDecrease,.leastNonzeroMagnitude)}else if ratio<0.25{damping*=options.dampingIncrease};acceptedSteps += 1;break }
                    }
                }
                damping *= options.dampingIncrease; rejectedSteps += 1; if !damping.isFinite { break }
            }
            guard let next=accepted else{return finish(iteration,.dampingLimit,gnorm)}
            let change=cost-next.2;point=next.0;value=next.1;cost=next.2
            let ng=inf8(projectedGradient8(point,normal8(scaled8(value,weights,loss),point.count).1,bounds))
            if observer?(.init(iteration:iteration+1,cost:cost,gradientNorm:ng,stepNorm:next.3,damping:damping,evaluations:evaluations)) == false{return finish(iteration+1,.cancelled,ng)}
            if next.3 <= options.stepTolerance*(1+norm8(point)){return finish(iteration+1,.convergedStep,ng)}
            if change <= options.costTolerance*(1+cost){return finish(iteration+1,.convergedObjective,ng)}
        }
        return finish(options.maxIterations,.iterationLimit,inf8(projectedGradient8(point,normal8(scaled8(value,weights,loss),point.count).1,bounds)))
    }
}

private func validBound(_ b:ParameterBound)->Bool{(b.lower?.isFinite ?? true)&&(b.upper?.isFinite ?? true)&&((b.lower ?? -.infinity)<=(b.upper ?? .infinity))}
private func project(_ pair:(Double,ParameterBound))->Double{max(pair.1.lower ?? -.infinity,min(pair.0,pair.1.upper ?? .infinity))}
private func validLoss(_ l:RobustLoss)->Bool{switch l{case .squared:return true;case .huber(let s),.cauchy(let s):return s.isFinite&&s>0}}
private func projectedGradient8(_ x:[Double],_ g:[Double],_ b:[ParameterBound])->[Double]{zip(zip(x,g),b).map{let((x,g),b)=$0;return ((b.lower.map{x <= $0} ?? false)&&g>0)||((b.upper.map{x >= $0} ?? false)&&g<0) ? 0:g}}
private func checkedModel8(_ m:NonlinearLeastSquares.Model,_ x:[Double])throws->NonlinearLeastSquaresEvaluation{let v=try m(x);guard !v.residuals.isEmpty,v.jacobian.count==v.residuals.count,v.jacobian.allSatisfy({$0.count==x.count}),v.residuals.allSatisfy(\.isFinite),v.jacobian.joined().allSatisfy(\.isFinite)else{throw NonlinearOptimizationError.invalidEvaluation("residuals must be non-empty and Jacobian must be finite m by n")};return v}
private func robustCost8(_ r:[Double],_ w:[Double],_ l:RobustLoss)->Double{r.enumerated().reduce(0){z,p in let v=p.element,rho:Double;switch l{case .squared:rho=0.5*v*v;case .huber(let s):rho=abs(v)<=s ? 0.5*v*v:s*(abs(v)-0.5*s);case .cauchy(let s):rho=0.5*s*s*log1p((v/s)*(v/s))};return z+(w.isEmpty ? 1:w[p.offset])*rho}}
private func scaled8(_ v:NonlinearLeastSquaresEvaluation,_ w:[Double],_ l:RobustLoss)->NonlinearLeastSquaresEvaluation{var r:[Double]=[],j:[[Double]]=[];for i in v.residuals.indices{let x=v.residuals[i],rw:Double;switch l{case .squared:rw=1;case .huber(let s):rw=(abs(x)<=s||x==0) ? 1:s/abs(x);case .cauchy(let s):rw=1/(1+(x/s)*(x/s))};let q=sqrt((w.isEmpty ? 1:w[i])*rw);r.append(q*x);j.append(v.jacobian[i].map{q*$0})};return .init(residuals:r,jacobian:j)}
private func normal8(_ v:NonlinearLeastSquaresEvaluation,_ n:Int)->([[Double]],[Double]){var a=[[Double]](repeating:[Double](repeating:0,count:n),count:n),g=[Double](repeating:0,count:n);for(row,r)in zip(v.jacobian,v.residuals){for i in 0..<n{g[i]+=row[i]*r;for k in 0...i{a[i][k]+=row[i]*row[k]}}};for i in 0..<n{for k in 0..<i{a[k][i]=a[i][k]}};return(a,g)}
private func predicted8(_ g:[Double],_ a:[[Double]],_ s:[Double])->Double{-dot8(g,s)-a.indices.reduce(0){$0+0.5*s[$1]*dot8(a[$1],s)}}
private func dot8(_ a:[Double],_ b:[Double])->Double{zip(a,b).reduce(0){$0+$1.0*$1.1}}
private func norm8(_ a:[Double])->Double{sqrt(dot8(a,a))}
private func inf8(_ a:[Double])->Double{a.map(abs).max() ?? 0}
private func qr8(_ matrix:[[Double]],_ rhs:[Double],_ tol:Double)->[Double]?{let m=matrix.count;guard let n=matrix.first?.count,m>=n,n>0,rhs.count==m else{return nil};var r=matrix,b=rhs;let scale=max(matrix.joined().map(abs).max() ?? 0,1);for c in 0..<n{let cn=sqrt((c..<m).reduce(0){$0+r[$1][c]*r[$1][c]});guard cn>tol*scale else{return nil};let alpha=r[c][c]>=0 ? -cn:cn;var v=(c..<m).map{r[$0][c]};v[0]-=alpha;let vn=dot8(v,v);for j in c..<n{let p=2*v.indices.reduce(0){$0+v[$1]*r[c+$1][j]}/vn;for k in v.indices{r[c+k][j]-=p*v[k]}};let p=2*v.indices.reduce(0){$0+v[$1]*b[c+$1]}/vn;for k in v.indices{b[c+k]-=p*v[k]}};var x=[Double](repeating:0,count:n);for i in (0..<n).reversed(){guard abs(r[i][i])>tol*scale else{return nil};let tail=i+1<n ? ((i+1)..<n).reduce(0){$0+r[i][$1]*x[$1]}:0;x[i]=(b[i]-tail)/r[i][i]};return x}
