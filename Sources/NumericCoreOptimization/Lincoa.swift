import NCBindings
import NumericCore

public struct LincoaOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var maxEvaluations: Int
    public var initialRadius: Double
    public var finalRadius: Double
    /// Absolute tolerance in the units of the original rows and variable bounds.
    public var feasibilityTolerance: Double

    public init(maxIterations: Int = 1_000, maxEvaluations: Int = 1_000, initialRadius: Double = 1,
                finalRadius: Double = 1e-7, feasibilityTolerance: Double = 1e-8) {
        self.maxIterations = maxIterations
        self.maxEvaluations = maxEvaluations
        self.initialRadius = initialRadius
        self.finalRadius = finalRadius
        self.feasibilityTolerance = feasibilityTolerance
    }
}

public enum LincoaTermination: Sendable, Hashable {
    /// The algorithm completed its final trust-region stage.
    case radiusReached
    case evaluationLimit
    case iterationLimit
    case numericalFailure
    case allVariablesFixed
}

public struct LincoaResult: Sendable, Hashable {
    public let point: [Double]
    public let objective: Double
    /// Maximum violation recomputed against the original rows and variable bounds.
    public let maximumViolation: Double
    public let evaluations: Int
    public let termination: LincoaTermination
}

/// Powell's derivative-free quadratic interpolation solver for linear inequalities.
public enum LincoaSolver {
    public static var isAvailable: Bool {
        NumericCoreAPI.supports("lincoa")
    }

    /// The linear objective coefficients in `problem` are ignored. The initial
    /// point must satisfy the rows and bounds after fixed coordinates are set to
    /// their bounds. Integer variables and nonconstant equality rows are unsupported.
    ///
    /// The synchronous objective must accept possibly infeasible trial points.
    /// The returned point meets the configured feasibility tolerance.
    public static func minimize(
        initial: [Double], problem: SparseLinearProblem, options: LincoaOptions = .init(),
        objective: @escaping ([Double]) throws -> Double
    ) throws -> LincoaResult {
        #if NUMERICCORE_LINCOA_FFI
        guard options.maxIterations > 0, options.maxEvaluations > 0,
              UInt32(exactly: problem.rows) != nil,
              UInt32(exactly: problem.columns) != nil,
              UInt32(exactly: problem.values.count) != nil else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid LINCOA budget or matrix dimensions")
        }

        let callback = LincoaObjectiveBridge(objective)
        let report: FfiLincoaResult
        do {
            report = try solveLincoa(
                initial: initial, problem: FFIKernels.makeFfiProblem(problem.ffi),
                options: .init(maxIterations: UInt64(options.maxIterations),
                               maxEvaluations: UInt64(options.maxEvaluations),
                               initialRadius: options.initialRadius, finalRadius: options.finalRadius,
                               feasibilityTolerance: options.feasibilityTolerance),
                objective: callback)
        } catch {
            if let original = callback.failure { throw original }
            throw FFIKernels.translate(error)
        }

        let termination: LincoaTermination
        switch report.termination {
        case .radiusReached: termination = .radiusReached
        case .evaluationLimit: termination = .evaluationLimit
        case .iterationLimit: termination = .iterationLimit
        case .numericalFailure: termination = .numericalFailure
        case .allVariablesFixed: termination = .allVariablesFixed
        }
        return .init(point: report.point, objective: report.objective, maximumViolation: report.maximumViolation,
                     evaluations: Int(report.evaluations), termination: termination)
        #else
        throw NCError.unsupportedOperation("The linked NumericCoreFFI does not provide LINCOA")
        #endif
    }
}

#if NUMERICCORE_LINCOA_FFI
private final class LincoaObjectiveBridge: FfiLincoaObjective {
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
