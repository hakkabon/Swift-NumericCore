import NCBindings
import NumericCore

public struct CobylaOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var maxEvaluations: Int
    public var initialRadius: Double
    public var finalRadius: Double
    public var feasibilityTolerance: Double

    public init(maxIterations: Int = 1_000, maxEvaluations: Int = 1_000,
                initialRadius: Double = 1, finalRadius: Double = 1e-7,
                feasibilityTolerance: Double = 1e-7) {
        self.maxIterations = maxIterations
        self.maxEvaluations = maxEvaluations
        self.initialRadius = initialRadius
        self.finalRadius = finalRadius
        self.feasibilityTolerance = feasibilityTolerance
    }
}

public enum CobylaTermination: Sendable, Hashable {
    case radiusReached
    case evaluationLimit
    case iterationLimit
    case numericalFailure
    case allVariablesFixed
}

public struct CobylaResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let constraintValues: [Double]
    public let maximumViolation: Double
    public let feasible: Bool
    public let evaluations: Int
    public let termination: CobylaTermination
}

/// Powell's derivative-free solver for general nonlinear constraints.
public enum CobylaSolver {
    public static var isAvailable: Bool {
        NumericCoreAPI.supports("cobyla")
    }

    /// The synchronous callback evaluates the full point. Trial points may
    /// violate variable bounds and constraints during simplex construction
    /// or restoration.
    public static func minimize(
        initial: [Double], bounds: [ParameterBound]? = nil,
        constraintKinds: [DerivativeFreeConstraintKind],
        options: CobylaOptions = .init(),
        evaluate: @escaping ConstrainedDerivativeFree.Evaluator
    ) throws -> CobylaResult {
        #if NUMERICCORE_COBYLA_FFI
        guard options.maxIterations > 0, options.maxEvaluations > 0 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid COBYLA iteration or evaluation budget")
        }
        let callback = CobylaEvaluatorBridge(evaluate)
        let report: FfiCobylaResult
        do {
            report = try solveCobyla(
                initial: initial,
                bounds: bounds?.map { .init(lower: $0.lower, upper: $0.upper) },
                constraintKinds: constraintKinds.map { $0 == .lessEqual ? .lessEqual : .equality },
                options: .init(maxIterations: UInt64(options.maxIterations),
                               maxEvaluations: UInt64(options.maxEvaluations),
                               initialRadius: options.initialRadius, finalRadius: options.finalRadius,
                               feasibilityTolerance: options.feasibilityTolerance),
                evaluator: callback)
        } catch {
            if let original = callback.failure { throw original }
            throw FFIKernels.translate(error)
        }
        let termination: CobylaTermination
        switch report.termination {
        case .radiusReached: termination = .radiusReached
        case .evaluationLimit: termination = .evaluationLimit
        case .iterationLimit: termination = .iterationLimit
        case .numericalFailure: termination = .numericalFailure
        case .allVariablesFixed: termination = .allVariablesFixed
        }
        return .init(point: report.point, objective: report.objective,
                     constraintValues: report.constraintValues, maximumViolation: report.maximumViolation,
                     feasible: report.feasible, evaluations: Int(report.evaluations), termination: termination)
        #else
        throw NCError.unsupportedOperation("The linked NumericCoreFFI does not provide COBYLA")
        #endif
    }
}

#if NUMERICCORE_COBYLA_FFI
private final class CobylaEvaluatorBridge: FfiCobylaEvaluator {
    private let callback: ConstrainedDerivativeFree.Evaluator
    private(set) var failure: Error?

    init(_ callback: @escaping ConstrainedDerivativeFree.Evaluator) {
        self.callback = callback
    }

    func evaluate(point: [Double]) -> FfiCobylaEvaluation? {
        do {
            let sample = try callback(point)
            return .init(objective: sample.objective, constraints: sample.constraints)
        } catch {
            failure = error
            return nil
        }
    }
}
#endif
