import NumericCore
import NumericCoreSparse

public enum EngineeringUnknownRole: Sendable, Hashable {
    case differential, algebraic, multiplier, reference
}

public struct EngineeringUnknown: Sendable, Hashable {
    public let name: String
    public let unit: String
    public let role: EngineeringUnknownRole
    public let scale: Double
    public let initialValue: Double
    public let initialDerivative: Double

    public init(name: String, unit: String, role: EngineeringUnknownRole,
                scale: Double = 1, initialValue: Double = 0,
                initialDerivative: Double = 0) {
        self.name = name; self.unit = unit; self.role = role; self.scale = scale
        self.initialValue = initialValue; self.initialDerivative = initialDerivative
    }
}

public struct EngineeringParameter: Sendable, Hashable {
    public let name: String
    public let unit: String
    public let value: Double
    public init(name: String, unit: String, value: Double) {
        self.name = name; self.unit = unit; self.value = value
    }
}

/// `orientation` is topology metadata; constitutive expressions receive the
/// unweighted unknown value in port order.
public struct EngineeringPort: Sendable, Hashable {
    public let name: String
    public let unknown: Int
    public let orientation: Double
    public init(name: String, unknown: Int, orientation: Double = 1) {
        self.name = name; self.unknown = unknown; self.orientation = orientation
    }
}

public struct EngineeringEquation: Sendable, Hashable {
    public let row: Int
    public let expression: NonlinearExpression
    public init(row: Int, expression: NonlinearExpression) {
        self.row = row; self.expression = expression
    }
}

public struct EngineeringElement: Sendable, Hashable {
    public let name: String
    public let kind: String
    /// Port order defines local state and derivative input order.
    public let ports: [EngineeringPort]
    public let equations: [EngineeringEquation]
    public init(name: String, kind: String, ports: [EngineeringPort],
                equations: [EngineeringEquation]) {
        self.name = name; self.kind = kind; self.ports = ports; self.equations = equations
    }
}

public struct EngineeringAssembly {
    public let residuals: [Double]
    public let jacobianState: SparseMatrix<Double>
    public let jacobianDerivative: SparseMatrix<Double>
    public let parameterJacobian: SparseMatrix<Double>

    public func daeEvaluation() -> DAEEvaluation {
        .init(residuals: residuals, jacobianState: engineeringDense(jacobianState),
              jacobianDerivative: engineeringDense(jacobianDerivative))
    }
}

/// Shared graph representation for circuit stamps, finite elements, and other
/// component-based residual models.
public struct EngineeringModel: Sendable, Hashable {
    public let unknowns: [EngineeringUnknown]
    public let parameters: [EngineeringParameter]
    public let elements: [EngineeringElement]

    public init(unknowns: [EngineeringUnknown], parameters: [EngineeringParameter] = [],
                elements: [EngineeringElement]) throws {
        self.unknowns = unknowns; self.parameters = parameters; self.elements = elements
        try validate()
    }

    public func validate() throws {
        guard !unknowns.isEmpty else { throw engineeringInvalid("engineering model must contain unknowns") }
        try engineeringUnique(unknowns.map(\.name), kind: "unknown")
        try engineeringUnique(parameters.map(\.name), kind: "parameter")
        try engineeringUnique(elements.map(\.name), kind: "element")
        guard unknowns.allSatisfy({ !$0.unit.isEmpty && $0.scale.isFinite && $0.scale > 0
            && $0.initialValue.isFinite && $0.initialDerivative.isFinite }) else {
            throw engineeringInvalid("invalid engineering unknown metadata")
        }
        guard parameters.allSatisfy({ !$0.unit.isEmpty && $0.value.isFinite }) else {
            throw engineeringInvalid("invalid engineering parameter metadata")
        }
        var covered = [Bool](repeating: false, count: unknowns.count)
        for element in elements {
            guard !element.kind.isEmpty, !element.ports.isEmpty, !element.equations.isEmpty else {
                throw engineeringInvalid("engineering elements need a kind, ports, and equations")
            }
            try engineeringUnique(element.ports.map(\.name), kind: "port")
            guard element.ports.allSatisfy({ unknowns.indices.contains($0.unknown) && $0.orientation.isFinite }) else {
                throw engineeringInvalid("invalid engineering port")
            }
            let inputCount = 1 + 2 * element.ports.count + parameters.count
            for equation in element.equations {
                guard unknowns.indices.contains(equation.row) else {
                    throw engineeringInvalid("engineering equation row is out of range")
                }
                try equation.expression.validate(parameterCount: inputCount)
                covered[equation.row] = true
            }
        }
        guard covered.allSatisfy({ $0 }) else {
            throw engineeringInvalid("every engineering residual row needs an element contribution")
        }
    }

    public var initialState: [Double] { unknowns.map(\.initialValue) }
    public var initialDerivative: [Double] { unknowns.map(\.initialDerivative) }

    /// Element-by-unknown signed incidence matrix. Duplicate ports are summed.
    public func incidenceMatrix() throws -> SparseMatrix<Double> {
        try SparseMatrix(rows: elements.count, cols: unknowns.count,
            entries: elements.enumerated().flatMap { row, element in
                element.ports.map { .init(row: row, column: $0.unknown, value: $0.orientation) }
            })
    }

    /// Evaluates every element and scatters exact local derivatives into
    /// global sparse state, derivative, and parameter Jacobians.
    public func assemble(time: Double, state: [Double], derivative: [Double]) throws
        -> EngineeringAssembly {
        guard time.isFinite, state.count == unknowns.count,
              derivative.count == unknowns.count,
              state.allSatisfy(\.isFinite), derivative.allSatisfy(\.isFinite) else {
            throw engineeringInvalid("invalid engineering evaluation point")
        }
        var residuals = [Double](repeating: 0, count: unknowns.count)
        var stateEntries: [SparseEntry<Double>] = []
        var derivativeEntries: [SparseEntry<Double>] = []
        var parameterEntries: [SparseEntry<Double>] = []
        for element in elements {
            let local = element.ports.count
            let input = [time]
                + element.ports.map { state[$0.unknown] }
                + element.ports.map { derivative[$0.unknown] }
                + parameters.map(\.value)
            for equation in element.equations {
                let value = try equation.expression.evaluate(parameters: input)
                residuals[equation.row] += value.value
                for (index, port) in element.ports.enumerated() {
                    engineeringPush(&stateEntries, row: equation.row, column: port.unknown,
                                    value: value.gradient[1 + index])
                    engineeringPush(&derivativeEntries, row: equation.row, column: port.unknown,
                                    value: value.gradient[1 + local + index])
                }
                for parameter in parameters.indices {
                    engineeringPush(&parameterEntries, row: equation.row, column: parameter,
                                    value: value.gradient[1 + 2 * local + parameter])
                }
            }
        }
        guard residuals.allSatisfy(\.isFinite) else {
            throw engineeringInvalid("engineering assembly produced non-finite residuals")
        }
        return .init(residuals: residuals,
            jacobianState: try SparseMatrix(rows: unknowns.count, cols: unknowns.count,
                                            entries: stateEntries),
            jacobianDerivative: try SparseMatrix(rows: unknowns.count, cols: unknowns.count,
                                                 entries: derivativeEntries),
            parameterJacobian: try SparseMatrix(rows: unknowns.count, cols: parameters.count,
                                                entries: parameterEntries))
    }

    /// Convenience bridge to Phase 39's residual-form DAE integrator.
    public func daeEvaluation(time: Double, state: [Double], derivative: [Double]) throws
        -> DAEEvaluation {
        try assemble(time: time, state: state, derivative: derivative).daeEvaluation()
    }
}

private func engineeringPush(_ entries: inout [SparseEntry<Double>], row: Int,
                             column: Int, value: Double) {
    if value != 0 { entries.append(.init(row: row, column: column, value: value)) }
}
private func engineeringUnique(_ names: [String], kind: String) throws {
    guard names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count else {
        throw engineeringInvalid("\(kind) names must be non-empty and unique")
    }
}
private func engineeringDense(_ matrix: SparseMatrix<Double>) -> [[Double]] {
    var result = [[Double]](repeating: [Double](repeating: 0, count: matrix.cols), count: matrix.rows)
    for row in 0..<matrix.rows {
        for index in matrix.csrRowPointers[row]..<matrix.csrRowPointers[row + 1] {
            result[row][matrix.csrColumnIndices[index]] = matrix.csrValues[index]
        }
    }
    return result
}
private func engineeringInvalid(_ message: String) -> NonlinearOptimizationError {
    .invalidConfiguration(message)
}
