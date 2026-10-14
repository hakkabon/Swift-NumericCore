import Foundation

public enum DerivativeFreeConstraintKind: Sendable, Hashable { case lessEqual, equality }

public struct ConstrainedDerivativeFreeEvaluation: Sendable, Hashable {
    public let objective: Double
    public let constraints: [Double]
    public init(objective: Double, constraints: [Double]) {
        self.objective = objective; self.constraints = constraints
    }
}

public struct ConstrainedDerivativeFreeOptions: Sendable, Hashable {
    public var maxIterations: Int; public var maxEvaluations: Int
    public var initialRadius: Double; public var finalRadius: Double; public var maximumRadius: Double
    public var feasibilityTolerance: Double; public var objectiveTolerance: Double
    public var initialPenalty: Double; public var penaltyGrowth: Double; public var maximumPenalty: Double
    public var acceptanceThreshold: Double; public var contraction: Double; public var expansion: Double
    public var subproblemIterations: Int
    public init(maxIterations: Int = 1_000, maxEvaluations: Int = 20_000,
                initialRadius: Double = 1, finalRadius: Double = 1e-7, maximumRadius: Double = 100,
                feasibilityTolerance: Double = 1e-7, objectiveTolerance: Double = 1e-12,
                initialPenalty: Double = 10, penaltyGrowth: Double = 10, maximumPenalty: Double = 1e12,
                acceptanceThreshold: Double = 0.1, contraction: Double = 0.5,
                expansion: Double = 1.5, subproblemIterations: Int = 80) {
        self.maxIterations=maxIterations;self.maxEvaluations=maxEvaluations;self.initialRadius=initialRadius
        self.finalRadius=finalRadius;self.maximumRadius=maximumRadius
        self.feasibilityTolerance=feasibilityTolerance;self.objectiveTolerance=objectiveTolerance
        self.initialPenalty=initialPenalty;self.penaltyGrowth=penaltyGrowth;self.maximumPenalty=maximumPenalty
        self.acceptanceThreshold=acceptanceThreshold;self.contraction=contraction;self.expansion=expansion
        self.subproblemIterations=subproblemIterations
    }
}

public enum ConstrainedDerivativeFreeTermination: Sendable, Hashable {
    case converged, infeasibleStationary, iterationLimit, evaluationLimit, cancelled
}
public struct ConstrainedDerivativeFreeIteration: Sendable, Hashable {
    public let iteration:Int;public let point:[Double];public let objective:Double
    public let maximumViolation:Double;public let evaluations:Int;public let radius:Double;public let penalty:Double
}
public struct ConstrainedDerivativeFreeResult: Sendable, Hashable {
    public let point:[Double];public let objective:Double;public let constraintValues:[Double]
    public let maximumViolation:Double;public let violationSum:Double
    public let iterations:Int;public let evaluations:Int;public let modelBuilds:Int;public let acceptedSteps:Int
    public let feasibilityImprovingSteps:Int;public let penaltyUpdates:Int
    public let finalPenalty:Double;public let finalRadius:Double;public let lastReductionRatio:Double
    public let termination:ConstrainedDerivativeFreeTermination
}

public enum ConstrainedDerivativeFree {
    public typealias Evaluator = ([Double]) throws -> ConstrainedDerivativeFreeEvaluation
    public typealias Observer = (ConstrainedDerivativeFreeIteration) -> Bool
    public static func minimize(initial:[Double],bounds:[ParameterBound]?=nil,
        constraintKinds:[DerivativeFreeConstraintKind],options:ConstrainedDerivativeFreeOptions = .init(),
        observer:Observer?=nil,evaluate:Evaluator)throws->ConstrainedDerivativeFreeResult{
        let box=try cdfValidate(initial,bounds,constraintKinds,options)
        var point=cdfProject(initial,box),current=try cdfChecked(evaluate,cdfProject(initial,box),constraintKinds.count)
        var evaluations=1,radius=options.initialRadius,penalty=options.initialPenalty
        var modelBuilds=0,acceptedSteps=0,feasibilitySteps=0,penaltyUpdates=0,lastRatio=Double.nan
        func result(_ iteration:Int,_ termination:ConstrainedDerivativeFreeTermination)->ConstrainedDerivativeFreeResult{
            let violation=cdfViolations(current.constraints,constraintKinds)
            return .init(point:point,objective:current.objective,constraintValues:current.constraints,
                maximumViolation:violation.maximum,violationSum:violation.sum,iterations:iteration,
                evaluations:evaluations,modelBuilds:modelBuilds,acceptedSteps:acceptedSteps,
                feasibilityImprovingSteps:feasibilitySteps,penaltyUpdates:penaltyUpdates,
                finalPenalty:penalty,finalRadius:radius,lastReductionRatio:lastRatio,termination:termination)
        }
        for iteration in 0..<options.maxIterations {
            let maximum=cdfViolations(current.constraints,constraintKinds).maximum
            if radius<=options.finalRadius{return result(iteration,maximum<=options.feasibilityTolerance ? .converged:.infeasibleStationary)}
            if evaluations+initial.count+1>options.maxEvaluations{return result(iteration,.evaluationLimit)}
            if observer?(.init(iteration:iteration,point:point,objective:current.objective,
                maximumViolation:maximum,evaluations:evaluations,radius:radius,penalty:penalty)) == false {
                return result(iteration,.cancelled)
            }
            let model=try cdfLinearModels(point,current,radius,box,constraintKinds.count,evaluate,&evaluations)
            modelBuilds+=1
            let step=cdfModelStep(point,current,model.objective,model.constraints,constraintKinds,
                penalty,radius,box,options.subproblemIterations)
            let stepNorm=cdfNorm(step)
            if stepNorm<=options.finalRadius*0.1{radius*=options.contraction;continue}
            let predicted=cdfMerit(current,constraintKinds,penalty)-cdfLinearMerit(current,model.objective,
                model.constraints,step,constraintKinds,penalty)
            if !predicted.isFinite||predicted<=0{radius*=options.contraction;continue}
            let candidatePoint=cdfProject(zip(point,step).map(+),box)
            let candidate=try cdfChecked(evaluate,candidatePoint,constraintKinds.count);evaluations+=1
            let actual=cdfMerit(current,constraintKinds,penalty)-cdfMerit(candidate,constraintKinds,penalty)
            lastRatio=actual/predicted
            let candidateMaximum=cdfViolations(candidate.constraints,constraintKinds).maximum
            let feasibilityImproved=candidateMaximum+options.feasibilityTolerance*0.1<maximum
            let accepted=(lastRatio>=options.acceptanceThreshold&&actual>options.objectiveTolerance)||feasibilityImproved
            if accepted{if feasibilityImproved{feasibilitySteps+=1};point=candidatePoint;current=candidate;acceptedSteps+=1}
            if maximum>options.feasibilityTolerance&&candidateMaximum>=0.9*maximum&&penalty<options.maximumPenalty{
                penalty=min(options.maximumPenalty,penalty*options.penaltyGrowth);penaltyUpdates+=1}
            if !accepted||lastRatio<0.1{radius*=options.contraction}
            else if lastRatio>0.75&&stepNorm>=0.8*radius{radius=min(options.maximumRadius,radius*options.expansion)}
        }
        return result(options.maxIterations,.iterationLimit)
    }
}

private func cdfLinearModels(_ point:[Double],_ center:ConstrainedDerivativeFreeEvaluation,
    _ radius:Double,_ bounds:[ParameterBound],_ count:Int,_ evaluate:ConstrainedDerivativeFree.Evaluator,
    _ evaluations:inout Int)throws->(objective:[Double],constraints:[[Double]]){
    var objective=[Double](repeating:0,count:point.count),constraints=Array(repeating:objective,count:count)
    for i in point.indices{let plus=min(radius,(bounds[i].upper ?? .infinity)-point[i])
        let minus=min(radius,point[i]-(bounds[i].lower ?? -.infinity));let h=plus>=minus&&plus>1e-14 ? plus:-minus
        var sample=point;sample[i]+=h;let value=try cdfChecked(evaluate,sample,count);evaluations+=1
        objective[i]=(value.objective-center.objective)/h
        for j in 0..<count{constraints[j][i]=(value.constraints[j]-center.constraints[j])/h}}
    return(objective,constraints)
}
private func cdfModelStep(_ point:[Double],_ center:ConstrainedDerivativeFreeEvaluation,
    _ objective:[Double],_ constraints:[[Double]],_ kinds:[DerivativeFreeConstraintKind],
    _ penalty:Double,_ radius:Double,_ bounds:[ParameterBound],_ iterations:Int)->[Double]{
    var step=[Double](repeating:0,count:point.count),best=step
    var bestValue=cdfLinearMerit(center,objective,constraints,step,kinds,penalty)
    for iteration in 0..<iterations{var gradient=objective
        for j in kinds.indices{let value=center.constraints[j]+cdfDot(constraints[j],step)
            let weight:Double = kinds[j] == .lessEqual ? (value>0 ? penalty:0):(value>0 ? penalty:(value<0 ? -penalty:0))
            for i in gradient.indices{gradient[i]+=weight*constraints[j][i]}}
        let norm=cdfNorm(gradient);if norm<=1e-14{break};let length=radius/sqrt(Double(iteration+1))
        for i in step.indices{step[i]-=length*gradient[i]/norm
            step[i]=min((bounds[i].upper ?? .infinity)-point[i],max((bounds[i].lower ?? -.infinity)-point[i],step[i]))}
        let stepNorm=cdfNorm(step);if stepNorm>radius{step=step.map{$0*radius/stepNorm}}
        let value=cdfLinearMerit(center,objective,constraints,step,kinds,penalty)
        if value<bestValue{bestValue=value;best=step}}
    if cdfViolations(center.constraints,kinds).maximum<=1e-4{var tangent=objective
        for j in kinds.indices where kinds[j] == .equality || center.constraints[j]>=(-1e-4){
            let denominator=cdfDot(constraints[j],constraints[j]);if denominator>1e-20{
                let factor=cdfDot(tangent,constraints[j])/denominator
                for i in tangent.indices{tangent[i]-=factor*constraints[j][i]}}}
        let norm=cdfNorm(tangent);if norm>1e-14{var candidate=tangent.map{-radius*$0/norm}
            for i in candidate.indices{candidate[i]=min((bounds[i].upper ?? .infinity)-point[i],
                max((bounds[i].lower ?? -.infinity)-point[i],candidate[i]))}
            if cdfLinearMerit(center,objective,constraints,candidate,kinds,penalty)<bestValue{best=candidate}}}
    return best
}
private func cdfLinearMerit(_ center:ConstrainedDerivativeFreeEvaluation,_ objective:[Double],
    _ gradients:[[Double]],_ step:[Double],_ kinds:[DerivativeFreeConstraintKind],_ penalty:Double)->Double{
    center.objective+cdfDot(objective,step)+penalty*kinds.indices.reduce(0){$0+cdfViolation(center.constraints[$1]+cdfDot(gradients[$1],step),kinds[$1])}}
private func cdfMerit(_ value:ConstrainedDerivativeFreeEvaluation,_ kinds:[DerivativeFreeConstraintKind],_ penalty:Double)->Double{value.objective+penalty*cdfViolations(value.constraints,kinds).sum}
private func cdfViolation(_ value:Double,_ kind:DerivativeFreeConstraintKind)->Double{kind == .lessEqual ? max(0,value):abs(value)}
private func cdfViolations(_ values:[Double],_ kinds:[DerivativeFreeConstraintKind])->(maximum:Double,sum:Double){zip(values,kinds).map(cdfViolation).reduce((0,0)){(max($0.0,$1),$0.1+$1)}}
private func cdfChecked(_ evaluate:ConstrainedDerivativeFree.Evaluator,_ point:[Double],_ count:Int)throws->ConstrainedDerivativeFreeEvaluation{let value=try evaluate(point);guard value.objective.isFinite,value.constraints.count==count,value.constraints.allSatisfy(\.isFinite)else{throw NonlinearOptimizationError.invalidEvaluation("non-finite or dimensionally invalid constrained derivative-free evaluation")};return value}
private func cdfValidate(_ initial:[Double],_ bounds:[ParameterBound]?,_ kinds:[DerivativeFreeConstraintKind],_ o:ConstrainedDerivativeFreeOptions)throws->[ParameterBound]{let box=bounds ?? [ParameterBound](repeating:.free,count:initial.count)
    guard !initial.isEmpty,!kinds.isEmpty,initial.allSatisfy(\.isFinite),box.count==initial.count,
        box.allSatisfy({($0.lower?.isFinite ?? true)&&($0.upper?.isFinite ?? true)&&($0.lower ?? -.infinity)<($0.upper ?? .infinity)}),
        o.maxIterations>0,o.maxEvaluations>=initial.count+2,o.initialRadius.isFinite,o.initialRadius>0,
        o.finalRadius.isFinite,o.finalRadius>0,o.finalRadius<o.initialRadius,
        o.maximumRadius.isFinite,o.maximumRadius>=o.initialRadius,
        o.feasibilityTolerance.isFinite,o.feasibilityTolerance>0,
        o.objectiveTolerance.isFinite,o.objectiveTolerance>=0,
        o.initialPenalty.isFinite,o.initialPenalty>0,o.penaltyGrowth.isFinite,o.penaltyGrowth>1,
        o.maximumPenalty.isFinite,o.maximumPenalty>=o.initialPenalty,
        o.acceptanceThreshold>0,o.acceptanceThreshold<1,o.contraction>0,o.contraction<1,
        o.expansion.isFinite,o.expansion>1,o.subproblemIterations>0 else{throw NonlinearOptimizationError.invalidConfiguration("invalid constrained derivative-free problem or options")};return box}
private func cdfProject(_ point:[Double],_ bounds:[ParameterBound])->[Double]{zip(point,bounds).map{min($1.upper ?? .infinity,max($1.lower ?? -.infinity,$0))}}
private func cdfDot(_ a:[Double],_ b:[Double])->Double{zip(a,b).reduce(0){$0+$1.0*$1.1}}
private func cdfNorm(_ a:[Double])->Double{sqrt(cdfDot(a,a))}
