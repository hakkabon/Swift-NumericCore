import Foundation
import NCBindings
import NumericCore
import NumericCoreSparse

public struct EngineeringAdjointResponse: Sendable, Hashable {
    public let name: String
    public let adjoint: [Double]
    public let parameterGradient: [Double]
    public let adjointResidualNorm: Double
    public let adjointBackwardError: Double
}

public struct EngineeringAdjointResult: Sendable, Hashable {
    public let responses: [EngineeringAdjointResponse]
    public let operatingResidualNorm: Double
}

extension EngineeringModel {
    /// One transpose solve per response. The result has no state sensitivity matrix.
    public func adjointSensitivities(
        time: Double, state: [Double], derivative: [Double],
        derivativeSensitivityFactor alpha: Double = 0, responses: [EngineeringResponseGradient]
    ) throws -> EngineeringAdjointResult {
        #if NUMERICCORE_ENGINEERING_ADJOINTS_FFI
        let model = try engineeringFFIModel(self)
        let result = try engineeringAdjointFFI {
            try solveEngineeringPointAdjoints(
                model: model, time: time, state: state, derivative: derivative, alpha: alpha,
                responses: responses.map { .init(name: $0.name, stateGradient: $0.stateGradient,
                                                  directParameterGradient: $0.directParameterGradient) })
        }
        return .init(responses: result.responses.map {
            .init(name: $0.name, adjoint: $0.adjoint, parameterGradient: $0.parameterGradient,
                  adjointResidualNorm: $0.adjointResidualNorm, adjointBackwardError: $0.adjointBackwardError)
        }, operatingResidualNorm: result.operatingResidualNorm)
        #else
        guard alpha.isFinite, !responses.isEmpty,
              Set(responses.map(\.name)).count == responses.count,
              responses.allSatisfy({ !$0.name.isEmpty && $0.stateGradient.count == unknowns.count
                && $0.directParameterGradient.count == parameters.count
                && $0.stateGradient.allSatisfy(\.isFinite)
                && $0.directParameterGradient.allSatisfy(\.isFinite) }) else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid engineering adjoint request")
        }
        let assembly = try assemble(time: time, state: state, derivative: derivative)
        let tangent = try engineeringEffectiveTangent(assembly, alpha: alpha)
        let factor = try SparseLUFactorization(matrix: tangent.transposed())
        let parameterTranspose = try assembly.parameterJacobian.transposed()
        let values = try responses.map { response in
            let result = try factor.solveRefined(response.stateGradient)
            let implicit = try parameterTranspose.multiplying(Vector(result.solution)).storage
            let gradient = zip(response.directParameterGradient, implicit).map(-)
            guard gradient.allSatisfy(\.isFinite), result.backwardError.isFinite, result.residualNorm.isFinite else {
                throw NonlinearOptimizationError.invalidEvaluation("non-finite engineering adjoint")
            }
            return EngineeringAdjointResponse(name: response.name, adjoint: result.solution, parameterGradient: gradient,
                                              adjointResidualNorm: result.residualNorm, adjointBackwardError: result.backwardError)
        }
        return .init(responses: values, operatingResidualNorm: assembly.residuals.reduce(0.0, hypot))
        #endif
    }
}

public struct EngineeringTrajectoryOptions: Sendable, Hashable {
    public var checkpointStride: UInt64
    public var maxNewtonIterations: UInt64
    public var residualTolerance: Double
    public var linearBackwardErrorTolerance: Double

    public init(checkpointStride: UInt64 = 32, maxNewtonIterations: UInt64 = 16,
                residualTolerance: Double = 1e-10, linearBackwardErrorTolerance: Double = 1e-10) {
        self.checkpointStride = checkpointStride
        self.maxNewtonIterations = maxNewtonIterations
        self.residualTolerance = residualTolerance
        self.linearBackwardErrorTolerance = linearBackwardErrorTolerance
    }
}

public struct EngineeringTrajectoryCheckpoint: Sendable, Hashable {
    public let step: UInt64
    public let time: Double
    public let state: [Double]
}

/// Scalar response with right-endpoint running quadrature and a terminal term.
/// Graph inputs are time, states, derivatives, and model parameters in order.
public struct EngineeringTrajectoryResponse: Sendable, Hashable {
    public let name: String
    public let running: NonlinearExpression?
    public let terminal: NonlinearExpression?

    public init(name: String, running: NonlinearExpression? = nil, terminal: NonlinearExpression? = nil) {
        self.name = name
        self.running = running
        self.terminal = terminal
    }
}

public struct EngineeringTrajectoryGradient: Sendable, Hashable {
    public let name: String
    public let value: Double
    /// Derivative with respect to model parameters with the initial state fixed.
    public let parameterGradient: [Double]
    public let initialStateGradient: [Double]
    public let maximumAdjointBackwardError: Double
}

public struct EngineeringTrajectoryAdjoints: Sendable, Hashable {
    public let responses: [EngineeringTrajectoryGradient]
    public let maximumPrimalResidual: Double
    public let replayedSteps: UInt64
    public let peakSegmentStates: UInt64
    public let transposeSolves: UInt64
    public let symbolicAnalyses: UInt64
}

/// A sparse backward-Euler trajectory on a prescribed time grid. The private
/// Rust handle is immutable and each adjoint call owns its replay workspace.
public final class EngineeringTrajectory: @unchecked Sendable {
    #if NUMERICCORE_ENGINEERING_ADJOINTS_FFI
    private let handle: FfiEngineeringTrajectory
    private let responseDimension: Int
    #endif

    public static var isAvailable: Bool {
        NumericCoreAPI.supports("engineering-adjoints")
    }

    public init(model: EngineeringModel, times: [Double], initialState: [Double]? = nil,
                options: EngineeringTrajectoryOptions = .init()) throws {
        #if NUMERICCORE_ENGINEERING_ADJOINTS_FFI
        let ffiModel = try engineeringFFIModel(model)
        handle = try engineeringAdjointFFI {
            try integrateEngineeringTrajectory(
                model: ffiModel, times: times, initialState: initialState ?? model.initialState,
                options: .init(checkpointStride: options.checkpointStride, maxNewtonIterations: options.maxNewtonIterations,
                               residualTolerance: options.residualTolerance,
                               linearBackwardErrorTolerance: options.linearBackwardErrorTolerance))
        }
        responseDimension = 1 + 2 * model.unknowns.count + model.parameters.count
        #else
        throw NonlinearOptimizationError.invalidConfiguration("The linked NumericCoreFFI does not provide engineering trajectories")
        #endif
    }

    public func checkpoints() -> [EngineeringTrajectoryCheckpoint] {
        #if NUMERICCORE_ENGINEERING_ADJOINTS_FFI
        handle.checkpoints().map { .init(step: $0.step, time: $0.time, state: $0.state) }
        #else
        []
        #endif
    }

    public func adjoints(_ responses: [EngineeringTrajectoryResponse]) throws -> EngineeringTrajectoryAdjoints {
        #if NUMERICCORE_ENGINEERING_ADJOINTS_FFI
        let requests: [FfiEngineeringTrajectoryResponse] = try responses.map {
            try .init(name: $0.name,
                      running: $0.running.map { try engineeringFFIGraph($0, dimension: responseDimension) },
                      terminal: $0.terminal.map { try engineeringFFIGraph($0, dimension: responseDimension) })
        }
        let result = try engineeringAdjointFFI { try handle.adjoints(responses: requests) }
        return .init(responses: result.responses.map {
            .init(name: $0.name, value: $0.value, parameterGradient: $0.parameterGradient,
                  initialStateGradient: $0.initialStateGradient, maximumAdjointBackwardError: $0.maximumAdjointBackwardError)
        }, maximumPrimalResidual: result.maximumPrimalResidual, replayedSteps: result.replayedSteps,
           peakSegmentStates: result.peakSegmentStates, transposeSolves: result.transposeSolves,
           symbolicAnalyses: result.symbolicAnalyses)
        #else
        throw NonlinearOptimizationError.invalidConfiguration("The linked NumericCoreFFI does not provide engineering trajectories")
        #endif
    }
}

#if NUMERICCORE_ENGINEERING_ADJOINTS_FFI
private func engineeringAdjointFFI<T>(_ run: () throws -> T) throws -> T {
    do { return try run() }
    catch { throw NonlinearOptimizationError.invalidEvaluation(String(describing: FFIKernels.translate(error))) }
}

private func engineeringFFIModel(_ model: EngineeringModel) throws -> FfiEngineeringModel {
    func index(_ value: Int) throws -> UInt32 {
        guard let value = UInt32(exactly: value) else { throw LPDecompositionError.indexOutsideFFIRange }
        return value
    }
    return try .init(
        unknowns: model.unknowns.map {
            let role: FfiEngineeringUnknownRole
            switch $0.role {
            case .differential: role = .differential
            case .algebraic: role = .algebraic
            case .multiplier: role = .multiplier
            case .reference: role = .reference
            }
            return .init(name: $0.name, unit: $0.unit, role: role, scale: $0.scale,
                         initialValue: $0.initialValue, initialDerivative: $0.initialDerivative)
        },
        parameters: model.parameters.map { .init(name: $0.name, unit: $0.unit, value: $0.value) },
        elements: model.elements.map { element in
            let dimension = 1 + 2 * element.ports.count + model.parameters.count
            return try .init(name: element.name, kind: element.kind,
                             ports: element.ports.map {
                try .init(name: $0.name, unknown: index($0.unknown), orientation: $0.orientation)
            }, equations: element.equations.map {
                try .init(row: index($0.row), expression: engineeringFFIGraph($0.expression, dimension: dimension))
            })
        })
}

private func engineeringFFIGraph(_ expression: NonlinearExpression, dimension: Int) throws -> FfiNonlinearExpression {
    guard UInt32(exactly: dimension) != nil, UInt32(exactly: expression.nodes.count) != nil else {
        throw LPDecompositionError.indexOutsideFFIRange
    }
    try expression.validate(parameterCount: dimension)
    return FFIKernels.makeFfiNonlinearExpression(NonlinearModelSolver.ffi(expression))
}
#endif
