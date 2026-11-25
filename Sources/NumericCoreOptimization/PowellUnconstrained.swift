import NCBindings
import NumericCore

public struct PowellUnconstrainedOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var maxEvaluations: Int
    public var initialRadius: Double
    public var finalRadius: Double

    public init(maxIterations: Int = 1_000, maxEvaluations: Int = 1_000,
                initialRadius: Double = 1, finalRadius: Double = 1e-7) {
        self.maxIterations = maxIterations
        self.maxEvaluations = maxEvaluations
        self.initialRadius = initialRadius
        self.finalRadius = finalRadius
    }
}

public enum PowellUnconstrainedTermination: Sendable, Hashable {
    /// The requested trust-region resolution was reached.
    case radiusReached
    case evaluationLimit
    case iterationLimit
    case numericalFailure
}

public struct PowellUnconstrainedResult: Sendable, Hashable {
    /// The best point actually evaluated by the objective callback.
    public let point: [Double]
    public let objective: Double
    public let evaluations: Int
    public let termination: PowellUnconstrainedTermination
}

/// Powell's unconstrained solver with `2n + 1` quadratic interpolation points.
public enum NewuoaSolver {
    public static var isAvailable: Bool { NumericCoreAPI.supports("newuoa") }

    /// The objective runs synchronously. The budget includes initialization.
    public static func minimize(
        initial: [Double], options: PowellUnconstrainedOptions = .init(),
        objective: @escaping ([Double]) throws -> Double
    ) throws -> PowellUnconstrainedResult {
        #if NUMERICCORE_NEWUOA_FFI
        return try minimizePowell(initial, options, objective, solveNewuoa)
        #else
        throw NCError.unsupportedOperation("The linked NumericCoreFFI does not provide NEWUOA")
        #endif
    }
}

/// Dense UOBYQA reference method with full quadratic interpolation.
public enum UobyqaSolver {
    public static var isAvailable: Bool { NumericCoreAPI.supports("uobyqa") }

    /// Supports up to 16 variables. The objective runs synchronously and the
    /// evaluation budget includes the full initial interpolation stencil.
    public static func minimize(
        initial: [Double], options: PowellUnconstrainedOptions = .init(),
        objective: @escaping ([Double]) throws -> Double
    ) throws -> PowellUnconstrainedResult {
        #if NUMERICCORE_UOBYQA_FFI
        return try minimizePowell(initial, options, objective, solveUobyqa)
        #else
        throw NCError.unsupportedOperation("The linked NumericCoreFFI does not provide UOBYQA")
        #endif
    }
}

#if NUMERICCORE_NEWUOA_FFI || NUMERICCORE_UOBYQA_FFI
private func minimizePowell(
    _ initial: [Double], _ options: PowellUnconstrainedOptions,
    _ objective: @escaping ([Double]) throws -> Double,
    _ solve: ([Double], FfiPowellUnconstrainedOptions, FfiPowellObjective) throws -> FfiPowellUnconstrainedResult
) throws -> PowellUnconstrainedResult {
    guard options.maxIterations > 0, options.maxEvaluations > 0 else {
        throw NonlinearOptimizationError.invalidConfiguration("invalid unconstrained Powell budget")
    }
    let callback = PowellObjectiveBridge(objective)
    let report: FfiPowellUnconstrainedResult
    do {
        report = try solve(initial, .init(maxIterations: UInt64(options.maxIterations),
                                          maxEvaluations: UInt64(options.maxEvaluations),
                                          initialRadius: options.initialRadius, finalRadius: options.finalRadius),
                           callback)
    } catch {
        if let original = callback.failure { throw original }
        throw FFIKernels.translate(error)
    }
    let termination: PowellUnconstrainedTermination
    switch report.termination {
    case .radiusReached: termination = .radiusReached
    case .evaluationLimit: termination = .evaluationLimit
    case .iterationLimit: termination = .iterationLimit
    case .numericalFailure: termination = .numericalFailure
    }
    return .init(point: report.point, objective: report.objective,
                 evaluations: Int(report.evaluations), termination: termination)
}

private final class PowellObjectiveBridge: FfiPowellObjective {
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
