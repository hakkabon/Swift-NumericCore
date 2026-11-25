import NCBindings
import NumericCore

public struct PowellHybridOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var maxResidualEvaluations: Int
    public var residualTolerance: Double
    /// Absolute tolerance for steps and the trust radius in scaled coordinates.
    public var stepTolerance: Double
    public var initialRadius: Double
    public var maximumRadius: Double
    /// Multipliers from scaled steps to physical steps. Empty means all ones.
    public var variableScale: [Double]
    /// Residual row multipliers. Empty means all ones.
    public var residualScale: [Double]

    public init(maxIterations: Int = 200, maxResidualEvaluations: Int = 500,
                residualTolerance: Double = 1e-9, stepTolerance: Double = 1e-12,
                initialRadius: Double = 1, maximumRadius: Double = 100,
                variableScale: [Double] = [], residualScale: [Double] = []) {
        self.maxIterations = maxIterations
        self.maxResidualEvaluations = maxResidualEvaluations
        self.residualTolerance = residualTolerance
        self.stepTolerance = stepTolerance
        self.initialRadius = initialRadius
        self.maximumRadius = maximumRadius
        self.variableScale = variableScale
        self.residualScale = residualScale
    }
}

public enum PowellHybridTermination: Sendable, Hashable {
    case convergedResidual
    /// A small step, small radius, or stationary residual merit above tolerance.
    case stalled
    case evaluationLimit
    case iterationLimit
    case numericalFailure
}

public struct PowellHybridResult: Sendable, Hashable {
    public let point: [Double]
    public let residuals: [Double]
    /// Euclidean norm after applying the configured residual scales.
    public let residualNorm: Double
    public let iterations: Int
    public let residualEvaluations: Int
    public let jacobianEvaluations: Int
    public let rankOneUpdates: Int
    public let acceptedSteps: Int
    public let finalRadius: Double
    public let termination: PowellHybridTermination
}

extension NonlinearSystemSolver {
    public static var isPowellHybridAvailable: Bool { NumericCoreAPI.supports("powell-hybrid") }

    /// Dense Powell hybrid method with separate synchronous residual and Jacobian callbacks.
    public static func solvePowellHybrid(
        initial: [Double], options: PowellHybridOptions = .init(),
        residual: @escaping Residual, jacobian: @escaping ([Double]) throws -> [[Double]]
    ) throws -> PowellHybridResult {
        #if NUMERICCORE_POWELL_HYBRID_FFI
        let bridge = PowellHybridBridge(residual: residual, jacobian: jacobian)
        do {
            let report = try runPowellHybrid(initial: initial, options: options.ffi(), system: bridge)
            return PowellHybridResult(report)
        } catch {
            if let original = bridge.failure { throw original }
            throw FFIKernels.translate(error)
        }
        #else
        throw NCError.unsupportedOperation("The linked NumericCoreFFI does not provide Powell hybrid")
        #endif
    }

    /// Solve a square equation graph inside Rust using value-only residual trials.
    public static func solvePowellHybrid(
        model: NonlinearEquationModel, initial: [Double], options: PowellHybridOptions = .init()
    ) throws -> PowellHybridResult {
        #if NUMERICCORE_POWELL_HYBRID_FFI
        guard initial.count == model.parameterCount,
              UInt32(exactly: model.parameterCount) != nil,
              model.equations.allSatisfy({ UInt32(exactly: $0.nodes.count) != nil }) else {
            throw NonlinearOptimizationError.invalidInitialPoint
        }
        let equations = model.equations.map {
            FFIKernels.makeFfiNonlinearExpression(NonlinearModelSolver.ffi($0))
        }
        do {
            let report = try runPowellHybridModel(initial: initial, equations: equations, options: options.ffi())
            return PowellHybridResult(report)
        } catch {
            throw FFIKernels.translate(error)
        }
        #else
        throw NCError.unsupportedOperation("The linked NumericCoreFFI does not provide Powell hybrid")
        #endif
    }
}

#if NUMERICCORE_POWELL_HYBRID_FFI
private extension PowellHybridOptions {
    func ffi() throws -> FfiPowellHybridOptions {
        guard maxIterations > 0, maxResidualEvaluations > 0 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid Powell hybrid budget")
        }
        return .init(maxIterations: UInt64(maxIterations), maxResidualEvaluations: UInt64(maxResidualEvaluations),
                     residualTolerance: residualTolerance, stepTolerance: stepTolerance,
                     initialRadius: initialRadius, maximumRadius: maximumRadius,
                     variableScale: variableScale, residualScale: residualScale)
    }
}

private extension PowellHybridResult {
    init(_ report: FfiPowellHybridResult) {
        point = report.point
        residuals = report.residuals
        residualNorm = report.residualNorm
        iterations = Int(report.iterations)
        residualEvaluations = Int(report.residualEvaluations)
        jacobianEvaluations = Int(report.jacobianEvaluations)
        rankOneUpdates = Int(report.rankOneUpdates)
        acceptedSteps = Int(report.acceptedSteps)
        finalRadius = report.finalRadius
        switch report.termination {
        case .convergedResidual: termination = .convergedResidual
        case .stalled: termination = .stalled
        case .evaluationLimit: termination = .evaluationLimit
        case .iterationLimit: termination = .iterationLimit
        case .numericalFailure: termination = .numericalFailure
        }
    }
}

private final class PowellHybridBridge: FfiPowellHybridSystem {
    private let residualCallback: NonlinearSystemSolver.Residual
    private let jacobianCallback: ([Double]) throws -> [[Double]]
    private(set) var failure: Error?

    init(residual: @escaping NonlinearSystemSolver.Residual, jacobian: @escaping ([Double]) throws -> [[Double]]) {
        residualCallback = residual
        jacobianCallback = jacobian
    }

    func residual(point: [Double]) -> [Double]? {
        call(residualCallback, point: point)
    }

    func jacobian(point: [Double]) -> [[Double]]? {
        call(jacobianCallback, point: point)
    }

    private func call<T>(_ callback: ([Double]) throws -> T, point: [Double]) -> T? {
        do {
            return try callback(point)
        } catch {
            failure = error
            return nil
        }
    }
}
#endif
