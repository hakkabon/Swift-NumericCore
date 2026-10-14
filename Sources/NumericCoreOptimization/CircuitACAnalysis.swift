import Foundation
import NumericCoreSparse

public struct CircuitComplex: Sendable, Hashable {
    public let real: Double
    public let imaginary: Double
    public var magnitude: Double { hypot(real, imaginary) }
    public var phase: Double { atan2(imaginary, real) }

    fileprivate static func polar(magnitude: Double, phase: Double) -> Self {
        .init(real: magnitude * cos(phase), imaginary: magnitude * sin(phase))
    }
}

public struct CircuitACExcitation: Sendable, Hashable {
    public let deviceName: String
    public let magnitude: Double
    public let phase: Double
    public init(deviceName: String, magnitude: Double, phase: Double = 0) {
        self.deviceName = deviceName; self.magnitude = magnitude; self.phase = phase
    }
}

public struct CircuitACPoint: Sendable, Hashable {
    public let frequency: Double
    public let unknowns: [CircuitComplex]
    public let residualNorm: Double
}

public struct CircuitACSweep: Sendable, Hashable {
    public let points: [CircuitACPoint]
}

public enum CircuitACTarget: Sendable, Hashable {
    case magnitude(frequency: Double, unknown: Int, target: Double, weight: Double)
}

public struct CircuitDesignVariable: Sendable, Hashable {
    public let name: String
    public let initial: Double
    public let lower: Double
    public let upper: Double
    public init(name: String, initial: Double, lower: Double, upper: Double) {
        self.name = name; self.initial = initial; self.lower = lower; self.upper = upper
    }
}

public struct CircuitOptimizationOptions: Sendable, Hashable {
    public var solver: LBFGSOptions
    public var relativeDifferenceStep: Double
    public init(solver: LBFGSOptions = .init(), relativeDifferenceStep: Double = 1e-5) {
        self.solver = solver; self.relativeDifferenceStep = relativeDifferenceStep
    }
}

public struct CircuitOptimizationResult: Sendable, Hashable {
    public let parameters: [Double]
    public let objective: Double
    public let gradient: [Double]
    public let iterations: Int
    public let evaluations: Int
    public let termination: NonlinearTermination
    public let sweep: CircuitACSweep
}

public extension CircuitModel {
    func acAnalysis(operatingState: [Double], frequencies: [Double],
                    excitations: [CircuitACExcitation]) throws -> CircuitACSweep {
        guard operatingState.count == unknownCount, !frequencies.isEmpty,
              frequencies.allSatisfy({ $0.isFinite && $0 >= 0 }), !excitations.isEmpty,
              excitations.allSatisfy({ !$0.deviceName.isEmpty && $0.magnitude.isFinite && $0.phase.isFinite })
        else { throw circuitACInvalid("invalid AC analysis configuration") }

        let assembly = try assemble(time: 0, state: operatingState, derivative: zeroDerivative)
        let conductance = circuitACDense(assembly.jacobianState)
        let storage = circuitACDense(assembly.jacobianDerivative)
        var rhs = [CircuitComplex](repeating: .init(real: 0, imaginary: 0), count: unknownCount)
        for excitation in excitations {
            guard let deviceIndex = devices.firstIndex(where: { $0.name == excitation.deviceName })
            else { throw circuitACInvalid("AC excitation device was not found") }
            let phasor = CircuitComplex.polar(magnitude: excitation.magnitude, phase: excitation.phase)
            switch devices[deviceIndex] {
            case .currentSource(_, let positive, let negative, _):
                if let index = try nodeUnknownIndex(positive) {
                    rhs[index] = .init(real: rhs[index].real - phasor.real,
                                       imaginary: rhs[index].imaginary - phasor.imaginary)
                }
                if let index = try nodeUnknownIndex(negative) {
                    rhs[index] = .init(real: rhs[index].real + phasor.real,
                                       imaginary: rhs[index].imaginary + phasor.imaginary)
                }
            case .voltageSource:
                guard let index = try branchUnknownIndex(deviceIndex) else {
                    throw circuitACInvalid("AC voltage source has no branch equation")
                }
                rhs[index] = .init(real: rhs[index].real + phasor.real,
                                   imaginary: rhs[index].imaginary + phasor.imaginary)
            default: throw circuitACInvalid("AC excitation must name an independent source")
            }
        }

        let n = unknownCount
        let points = try frequencies.map { frequency -> CircuitACPoint in
            let omega = 2 * Double.pi * frequency
            var matrix = [[Double]](repeating: [Double](repeating: 0, count: 2*n), count: 2*n)
            var blockRHS = [Double](repeating: 0, count: 2*n)
            for row in 0..<n {
                blockRHS[row] = rhs[row].real; blockRHS[row+n] = rhs[row].imaginary
                for column in 0..<n {
                    matrix[row][column] = conductance[row][column]
                    matrix[row][column+n] = -omega * storage[row][column]
                    matrix[row+n][column] = omega * storage[row][column]
                    matrix[row+n][column+n] = conductance[row][column]
                }
            }
            let solution = try circuitACSolve(matrix, blockRHS)
            let unknowns: [CircuitComplex] = (0..<n).map {
                CircuitComplex(real: solution[$0], imaginary: solution[$0+n])
            }
            var residualNorm = 0.0
            for row in 0..<n {
                var real = -rhs[row].real, imaginary = -rhs[row].imaginary
                for column in 0..<n {
                    real += conductance[row][column] * unknowns[column].real
                        - omega * storage[row][column] * unknowns[column].imaginary
                    imaginary += omega * storage[row][column] * unknowns[column].real
                        + conductance[row][column] * unknowns[column].imaginary
                }
                residualNorm = max(residualNorm, abs(real), abs(imaginary))
            }
            return .init(frequency: frequency, unknowns: unknowns, residualNorm: residualNorm)
        }
        return .init(points: points)
    }
}

public enum CircuitOptimization {
    public typealias Builder = ([Double]) throws -> CircuitModel

    public static func optimizeAC(variables: [CircuitDesignVariable],
                                  excitations: [CircuitACExcitation],
                                  targets: [CircuitACTarget],
                                  options: CircuitOptimizationOptions = .init(),
                                  build: @escaping Builder) throws -> CircuitOptimizationResult {
        try circuitACValidateOptimization(variables, targets, options)
        let initial = variables.map(\.initial)
        let bounds = variables.map { ParameterBound(lower: $0.lower, upper: $0.upper) }
        let frequencies = circuitACTargetFrequencies(targets)
        let result = try LBFGSB.minimize(initial: initial, bounds: bounds,
                                         options: options.solver) { parameters in
            let value = try circuitACObjective(parameters, frequencies, excitations, targets, build)
            var gradient = [Double](repeating: 0, count: parameters.count)
            for index in parameters.indices {
                let h = options.relativeDifferenceStep * max(abs(parameters[index]), 1)
                var plus = parameters, minus = parameters
                plus[index] = min(parameters[index] + h, variables[index].upper)
                minus[index] = max(parameters[index] - h, variables[index].lower)
                if plus[index] == minus[index] { continue }
                let high = try circuitACObjective(plus, frequencies, excitations, targets, build)
                let low = try circuitACObjective(minus, frequencies, excitations, targets, build)
                gradient[index] = (high - low) / (plus[index] - minus[index])
            }
            return (value, gradient)
        }
        let model = try build(result.point)
        let operating = try model.dcOperatingPointContinuation()
        let sweep = try model.acAnalysis(operatingState: operating.state,
                                         frequencies: frequencies, excitations: excitations)
        return .init(parameters: result.point, objective: result.objective,
                     gradient: result.gradient, iterations: result.iterations,
                     evaluations: result.evaluations, termination: result.termination,
                     sweep: sweep)
    }
}

private func circuitACObjective(_ parameters: [Double], _ frequencies: [Double],
                                _ excitations: [CircuitACExcitation],
                                _ targets: [CircuitACTarget],
                                _ build: CircuitOptimization.Builder) throws -> Double {
    let model = try build(parameters), operating = try model.dcOperatingPointContinuation()
    let sweep = try model.acAnalysis(operatingState: operating.state,
                                     frequencies: frequencies, excitations: excitations)
    var objective = 0.0
    for target in targets {
        switch target {
        case .magnitude(let frequency, let unknown, let desired, let weight):
            guard let point = sweep.points.first(where: { $0.frequency == frequency }),
                  point.unknowns.indices.contains(unknown)
            else { throw circuitACInvalid("AC target unknown is out of range") }
            objective += 0.5 * weight * pow(point.unknowns[unknown].magnitude - desired, 2)
        }
    }
    return objective
}

private func circuitACTargetFrequencies(_ targets: [CircuitACTarget]) -> [Double] {
    Array(Set(targets.map { target in
        switch target { case .magnitude(let frequency, _, _, _): return frequency }
    })).sorted()
}

private func circuitACValidateOptimization(_ variables: [CircuitDesignVariable],
                                           _ targets: [CircuitACTarget],
                                           _ options: CircuitOptimizationOptions) throws {
    guard !variables.isEmpty, Set(variables.map(\.name)).count == variables.count,
          variables.allSatisfy({ !$0.name.isEmpty && $0.initial.isFinite && $0.lower.isFinite && $0.upper.isFinite && $0.lower <= $0.initial && $0.initial <= $0.upper }),
          !targets.isEmpty, options.relativeDifferenceStep.isFinite,
          options.relativeDifferenceStep > 0 else { throw circuitACInvalid("invalid circuit optimization configuration") }
    guard targets.allSatisfy({ target in
        switch target { case .magnitude(let frequency, _, let desired, let weight):
            return frequency.isFinite && frequency >= 0 && desired.isFinite && desired >= 0 && weight.isFinite && weight > 0
        }
    }) else { throw circuitACInvalid("invalid AC optimization target") }
}

private func circuitACDense(_ matrix: SparseMatrix<Double>) -> [[Double]] {
    var result = [[Double]](repeating: [Double](repeating: 0, count: matrix.cols), count: matrix.rows)
    for row in 0..<matrix.rows { for index in matrix.csrRowPointers[row]..<matrix.csrRowPointers[row+1] {
        result[row][matrix.csrColumnIndices[index]] = matrix.csrValues[index]
    }}
    return result
}

private func circuitACSolve(_ input: [[Double]], _ inputRHS: [Double]) throws -> [Double] {
    var matrix = input, rhs = inputRHS; let n = rhs.count
    for column in 0..<n {
        let pivot = (column..<n).max { abs(matrix[$0][column]) < abs(matrix[$1][column]) }!
        guard abs(matrix[pivot][column]) > 1e-14 else { throw circuitACInvalid("singular AC system") }
        matrix.swapAt(column, pivot); rhs.swapAt(column, pivot)
        if column + 1 < n { for row in column+1..<n {
            let factor = matrix[row][column] / matrix[column][column]; matrix[row][column] = 0
            if column + 1 < n { for item in column+1..<n { matrix[row][item] -= factor * matrix[column][item] } }
            rhs[row] -= factor * rhs[column]
        }}
    }
    var solution = [Double](repeating: 0, count: n)
    for row in (0..<n).reversed() {
        var tail = 0.0; if row + 1 < n { for column in row+1..<n { tail += matrix[row][column] * solution[column] } }
        solution[row] = (rhs[row] - tail) / matrix[row][row]
    }
    guard solution.allSatisfy(\.isFinite) else { throw circuitACInvalid("non-finite AC solution") }
    return solution
}

private func circuitACInvalid(_ message: String) -> NonlinearOptimizationError {
    .invalidConfiguration(message)
}
