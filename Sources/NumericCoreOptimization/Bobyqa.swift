import NCBindings
import NumericCore

public struct BobyqaOptions: Sendable, Hashable {
    public var maxEvaluations: Int
    public var initialRadius: Double
    public var finalRadius: Double
    public var interpolationPoints: Int?

    public init(maxEvaluations: Int = 1_000, initialRadius: Double = 1,
                finalRadius: Double = 1e-6, interpolationPoints: Int? = nil) {
        self.maxEvaluations = maxEvaluations
        self.initialRadius = initialRadius
        self.finalRadius = finalRadius
        self.interpolationPoints = interpolationPoints
    }
}

public enum BobyqaTermination: Sendable, Hashable {
    /// The solver reached its final trust-region resolution.
    case radiusReached
    case evaluationLimit
    case modelDegenerate
    case allVariablesFixed
}

public struct BobyqaResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    public let evaluations: Int
    public let termination: BobyqaTermination
}

/// Powell's bound-constrained quadratic interpolation solver.
public enum BobyqaSolver {
    public static var isAvailable: Bool {
        NumericCoreAPI.supports("bobyqa")
    }

    /// The objective runs synchronously and receives the full feasible point.
    public static func minimize(
        initial: [Double], bounds: [ParameterBound], options: BobyqaOptions = .init(),
        objective: @escaping ([Double]) throws -> Double
    ) throws -> BobyqaResult {
        #if NUMERICCORE_BOBYQA_FFI
        guard options.maxEvaluations > 0,
              options.interpolationPoints.map({ $0 > 0 }) ?? true else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid BOBYQA budget or interpolation count")
        }
        let callback = BobyqaObjectiveBridge(objective)
        let report: FfiBobyqaResult
        do {
            report = try solveBobyqa(
                initial: initial,
                bounds: bounds.map { .init(lower: $0.lower, upper: $0.upper) },
                options: .init(maxEvaluations: UInt64(options.maxEvaluations),
                               initialRadius: options.initialRadius, finalRadius: options.finalRadius,
                               interpolationPoints: options.interpolationPoints.map { UInt64($0) }),
                objective: callback)
        } catch {
            if let original = callback.failure { throw original }
            throw FFIKernels.translate(error)
        }
        let termination: BobyqaTermination
        switch report.termination {
        case .radiusReached: termination = .radiusReached
        case .evaluationLimit: termination = .evaluationLimit
        case .modelDegenerate: termination = .modelDegenerate
        case .allVariablesFixed: termination = .allVariablesFixed
        }
        return .init(point: report.point, objective: report.objective,
                     evaluations: Int(report.evaluations), termination: termination)
        #else
        throw NCError.unsupportedOperation("The linked NumericCoreFFI does not provide BOBYQA")
        #endif
    }
}

#if NUMERICCORE_BOBYQA_FFI
private final class BobyqaObjectiveBridge: FfiBobyqaObjective {
    private let objective: ([Double]) throws -> Double
    private(set) var failure: Error?

    init(_ objective: @escaping ([Double]) throws -> Double) {
        self.objective = objective
    }

    func evaluate(point: [Double]) -> Double? {
        do {
            return try objective(point)
        } catch {
            failure = error
            return nil
        }
    }
}
#endif
