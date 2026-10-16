import Foundation
import NumericCoreSparse

public struct MultiphysicsDiscipline: Sendable, Hashable {
    public let name: String
    public let equationRows: [Int]
    public init(name: String, equationRows: [Int]) {
        self.name = name; self.equationRows = equationRows
    }
}

public enum MultiphysicsSteadyTermination: Sendable, Hashable {
    case convergedResidual, convergedStep, iterationLimit, lineSearchFailed
}

public struct MultiphysicsSteadyOptions: Sendable, Hashable {
    public var maxIterations: Int
    public var residualTolerance: Double
    public var stepTolerance: Double
    public var maximumLineSearchIterations: Int
    public var backtracking: Double
    public init(maxIterations: Int = 50, residualTolerance: Double = 1e-10,
                stepTolerance: Double = 1e-10, maximumLineSearchIterations: Int = 20,
                backtracking: Double = 0.5) {
        self.maxIterations = maxIterations; self.residualTolerance = residualTolerance
        self.stepTolerance = stepTolerance
        self.maximumLineSearchIterations = maximumLineSearchIterations
        self.backtracking = backtracking
    }
}

public struct MultiphysicsSteadyResult: Sendable, Hashable {
    public let state: [Double]
    public let residuals: [Double]
    public let residualNorm: Double
    public let disciplineResidualNorms: [String: Double]
    public let iterations: Int
    public let linearSolves: Int
    public let termination: MultiphysicsSteadyTermination
}

public struct MultiphysicsModel: Sendable, Hashable {
    public let engineeringModel: EngineeringModel
    public let disciplines: [MultiphysicsDiscipline]

    public init(engineeringModel: EngineeringModel,
                disciplines: [MultiphysicsDiscipline]) throws {
        self.engineeringModel = engineeringModel; self.disciplines = disciplines
        try validate()
    }

    public func validate() throws {
        guard !disciplines.isEmpty,
              Set(disciplines.map(\.name)).count == disciplines.count,
              disciplines.allSatisfy({ !$0.name.isEmpty && !$0.equationRows.isEmpty }) else {
            throw multiphysicsInvalid("multiphysics disciplines must be named and non-empty")
        }
        let rows = disciplines.flatMap(\.equationRows)
        guard rows.count == engineeringModel.unknowns.count,
              Set(rows).count == rows.count,
              Set(rows) == Set(engineeringModel.unknowns.indices) else {
            throw multiphysicsInvalid("discipline equation rows must partition the coupled system")
        }
    }

    public func replacingParameterValues(_ values: [Double]) throws -> MultiphysicsModel {
        guard values.count == engineeringModel.parameters.count,
              values.allSatisfy(\.isFinite) else {
            throw multiphysicsInvalid("replacement parameter values are invalid")
        }
        let parameters = zip(engineeringModel.parameters, values).map {
            EngineeringParameter(name: $0.0.name, unit: $0.0.unit, value: $0.1)
        }
        return try .init(engineeringModel: EngineeringModel(
            unknowns: engineeringModel.unknowns, parameters: parameters,
            elements: engineeringModel.elements), disciplines: disciplines)
    }

    public func solveSteady(initial: [Double]? = nil,
                            options: MultiphysicsSteadyOptions = .init()) throws
        -> MultiphysicsSteadyResult {
        try multiphysicsValidate(options)
        var state = initial ?? engineeringModel.initialState
        guard state.count == engineeringModel.unknowns.count,
              state.allSatisfy(\.isFinite) else {
            throw multiphysicsInvalid("invalid multiphysics initial state")
        }
        let derivative = [Double](repeating: 0, count: state.count)
        var linearSolves = 0
        for iteration in 0...options.maxIterations {
            let assembly = try engineeringModel.assemble(time: 0, state: state,
                                                         derivative: derivative)
            let norm = multiphysicsNorm(assembly.residuals)
            if norm <= options.residualTolerance {
                return finish(state, assembly.residuals, iteration, linearSolves,
                              .convergedResidual)
            }
            if iteration == options.maxIterations {
                return finish(state, assembly.residuals, iteration, linearSolves,
                              .iterationLimit)
            }
            let factor = try SparseLUFactorization(matrix: assembly.jacobianState)
            let step = try factor.solve(assembly.residuals.map(-)); linearSolves += 1
            if multiphysicsNorm(step) <= options.stepTolerance * (1 + multiphysicsNorm(state)) {
                return finish(state, assembly.residuals, iteration, linearSolves, .convergedStep)
            }
            var scale = 1.0, accepted: ([Double], [Double])?
            for _ in 0..<options.maximumLineSearchIterations {
                let candidate = zip(state, step).map { $0 + scale*$1 }
                if let next = try? engineeringModel.assemble(time: 0, state: candidate,
                                                             derivative: derivative),
                   multiphysicsNorm(next.residuals) < norm {
                    accepted = (candidate, next.residuals); break
                }
                scale *= options.backtracking
            }
            guard let next = accepted else {
                return finish(state, assembly.residuals, iteration, linearSolves,
                              .lineSearchFailed)
            }
            state = next.0
        }
        fatalError("unreachable")
    }

    private func finish(_ state: [Double], _ residuals: [Double], _ iterations: Int,
                        _ solves: Int, _ termination: MultiphysicsSteadyTermination)
        -> MultiphysicsSteadyResult {
        let byDiscipline = Dictionary(uniqueKeysWithValues: disciplines.map { discipline in
            (discipline.name, multiphysicsNorm(discipline.equationRows.map { residuals[$0] }))
        })
        return .init(state: state, residuals: residuals,
                     residualNorm: multiphysicsNorm(residuals),
                     disciplineResidualNorms: byDiscipline, iterations: iterations,
                     linearSolves: solves, termination: termination)
    }
}

public struct MultiphysicsDesignVariable: Sendable, Hashable {
    public let parameter: Int
    public let bound: ParameterBound
    public init(parameter: Int, bound: ParameterBound) {
        self.parameter = parameter; self.bound = bound
    }
}

public struct MultiphysicsDesignProblem: Sendable, Hashable {
    public let model: MultiphysicsModel
    /// Inputs are all steady states followed by all engineering parameters.
    public let response: NonlinearExpression
    public let designVariables: [MultiphysicsDesignVariable]

    public init(model: MultiphysicsModel, response: NonlinearExpression,
                designVariables: [MultiphysicsDesignVariable]) throws {
        self.model = model; self.response = response; self.designVariables = designVariables
        try validate()
    }

    public func validate() throws {
        try response.validate(parameterCount: model.engineeringModel.unknowns.count
                              + model.engineeringModel.parameters.count)
        let indices = designVariables.map(\.parameter)
        guard !indices.isEmpty, Set(indices).count == indices.count,
              indices.allSatisfy(model.engineeringModel.parameters.indices.contains),
              designVariables.allSatisfy({ multiphysicsValid($0.bound) }) else {
            throw multiphysicsInvalid("invalid multiphysics design variables")
        }
    }
}

public struct MultiphysicsDesignResult {
    public let design: [Double]
    public let state: [Double]
    public let response: Double
    public let gradient: [Double]
    public let steadyResult: MultiphysicsSteadyResult
    public let optimizationResult: LBFGSResult
    public let coupledSolves: Int
}

public enum MultiphysicsDesignOptimizer {
    public static func minimize(
        problem: MultiphysicsDesignProblem,
        steadyOptions: MultiphysicsSteadyOptions = .init(),
        optimizationOptions: LBFGSOptions = .init()
    ) throws -> MultiphysicsDesignResult {
        try problem.validate()
        let base = problem.model.engineeringModel.parameters.map(\.value)
        let initial = problem.designVariables.map { base[$0.parameter] }
        let bounds = problem.designVariables.map(\.bound)
        var warmState = problem.model.engineeringModel.initialState, coupledSolves = 0
        func evaluate(_ design: [Double]) throws
            -> (model: MultiphysicsModel, steady: MultiphysicsSteadyResult,
                value: Double, gradient: [Double]) {
            var parameters = base
            for (variable, value) in zip(problem.designVariables, design) {
                parameters[variable.parameter] = value
            }
            let model = try problem.model.replacingParameterValues(parameters)
            var steady = try model.solveSteady(initial: warmState, options: steadyOptions)
            if steady.termination != .convergedResidual {
                steady = try model.solveSteady(options: steadyOptions)
            }
            guard steady.termination == .convergedResidual else {
                throw multiphysicsInvalid("coupled steady solve did not converge")
            }
            coupledSolves += 1; warmState = steady.state
            let evaluated = try problem.response.evaluate(parameters: steady.state + parameters)
            let n = steady.state.count
            let sensitivity = try model.engineeringModel.sensitivities(
                time: 0, state: steady.state, derivative: [Double](repeating: 0, count: n),
                responses: [.init(name: "design-response",
                    stateGradient: Array(evaluated.gradient[..<n]),
                    directParameterGradient: Array(evaluated.gradient[n...]))])
            let total = sensitivity.responses[0].parameterGradient
            return (model, steady, evaluated.value,
                    problem.designVariables.map { total[$0.parameter] })
        }
        let optimized = try LBFGSB.minimize(initial: initial, bounds: bounds,
                                             options: optimizationOptions) { design in
            let value = try evaluate(design)
            return (value.value, value.gradient)
        }
        let final = try evaluate(optimized.point)
        return .init(design: optimized.point, state: final.steady.state,
                     response: final.value, gradient: final.gradient,
                     steadyResult: final.steady, optimizationResult: optimized,
                     coupledSolves: coupledSolves)
    }
}

private func multiphysicsValidate(_ options: MultiphysicsSteadyOptions) throws {
    guard options.maxIterations > 0, options.maximumLineSearchIterations > 0,
          options.residualTolerance.isFinite, options.residualTolerance > 0,
          options.stepTolerance.isFinite, options.stepTolerance > 0,
          options.backtracking.isFinite, options.backtracking > 0,
          options.backtracking < 1 else { throw multiphysicsInvalid("invalid steady solver options") }
}
private func multiphysicsValid(_ bound: ParameterBound) -> Bool {
    (bound.lower?.isFinite ?? true) && (bound.upper?.isFinite ?? true)
        && (bound.lower ?? -.infinity) <= (bound.upper ?? .infinity)
}
private func multiphysicsNorm(_ values: [Double]) -> Double {
    sqrt(values.reduce(0) { $0 + $1*$1 })
}
private func multiphysicsInvalid(_ message: String) -> NonlinearOptimizationError {
    .invalidConfiguration(message)
}
