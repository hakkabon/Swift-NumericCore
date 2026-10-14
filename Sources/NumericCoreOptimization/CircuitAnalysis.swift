import Foundation
import NumericCoreSparse

public struct CircuitNode: Sendable, Hashable {
    public let name: String
    public let initialVoltage: Double
    public init(name: String, initialVoltage: Double = 0) {
        self.name = name; self.initialVoltage = initialVoltage
    }
}

public enum CircuitWaveform: Sendable, Hashable {
    case constant(Double)
    case sinusoidal(offset: Double, amplitude: Double, frequency: Double, phase: Double)
    case pulse(low: Double, high: Double, delay: Double, rise: Double, fall: Double,
               width: Double, period: Double)

    public func value(at time: Double) -> Double {
        switch self {
        case .constant(let value): return value
        case .sinusoidal(let offset, let amplitude, let frequency, let phase):
            return offset + amplitude * sin(2 * .pi * frequency * time + phase)
        case .pulse(let low, let high, let delay, let rise, let fall, let width, let period):
            if time < delay { return low }
            let local = period > 0 ? (time - delay).truncatingRemainder(dividingBy: period) : time - delay
            if rise > 0 && local < rise { return low + (high - low) * local / rise }
            if local < rise + width { return high }
            if fall > 0 && local < rise + width + fall {
                return high + (low - high) * (local - rise - width) / fall
            }
            return low
        }
    }

    fileprivate var isValid: Bool {
        switch self {
        case .constant(let value): return value.isFinite
        case .sinusoidal(let offset, let amplitude, let frequency, let phase):
            return [offset, amplitude, frequency, phase].allSatisfy(\.isFinite) && frequency >= 0
        case .pulse(let low, let high, let delay, let rise, let fall, let width, let period):
            return [low, high, delay, rise, fall, width, period].allSatisfy(\.isFinite)
                && delay >= 0 && rise >= 0 && fall >= 0 && width >= 0 && period >= 0
                && (period == 0 || period >= rise + width + fall)
        }
    }
}

public struct CircuitSource: Sendable, Hashable {
    public let dcValue: Double
    public let transientWaveform: CircuitWaveform?
    public init(dcValue: Double, transientWaveform: CircuitWaveform? = nil) {
        self.dcValue = dcValue; self.transientWaveform = transientWaveform
    }
    public static func dc(_ value: Double) -> Self { .init(dcValue: value) }
    public static func transient(dc: Double, waveform: CircuitWaveform) -> Self {
        .init(dcValue: dc, transientWaveform: waveform)
    }
    fileprivate func value(at time: Double, transient: Bool) -> Double {
        transient ? transientWaveform?.value(at: time) ?? dcValue : dcValue
    }
    fileprivate var isValid: Bool {
        dcValue.isFinite && (transientWaveform?.isValid ?? true)
    }
}

public enum CircuitDevice: Sendable, Hashable {
    case resistor(name: String, positive: Int, negative: Int, resistance: Double)
    case capacitor(name: String, positive: Int, negative: Int, capacitance: Double)
    case inductor(name: String, positive: Int, negative: Int, inductance: Double,
                  initialCurrent: Double)
    case currentSource(name: String, positive: Int, negative: Int, source: CircuitSource)
    case voltageSource(name: String, positive: Int, negative: Int, source: CircuitSource,
                       initialCurrent: Double)
    case diode(name: String, anode: Int, cathode: Int, saturationCurrent: Double,
               thermalVoltage: Double)

    fileprivate var name: String {
        switch self {
        case .resistor(let name, _, _, _), .capacitor(let name, _, _, _),
             .inductor(let name, _, _, _, _), .currentSource(let name, _, _, _),
             .voltageSource(let name, _, _, _, _), .diode(let name, _, _, _, _): return name
        }
    }
    fileprivate var nodes: (Int, Int) {
        switch self {
        case .resistor(_, let p, let n, _), .capacitor(_, let p, let n, _),
             .inductor(_, let p, let n, _, _), .currentSource(_, let p, let n, _),
             .voltageSource(_, let p, let n, _, _): return (p, n)
        case .diode(_, let a, let c, _, _): return (a, c)
        }
    }
    fileprivate var hasBranch: Bool {
        switch self { case .inductor, .voltageSource: return true; default: return false }
    }
}

public struct CircuitOperatingPoint: Sendable, Hashable {
    public let nodeVoltages: [Double]
    public let branchCurrents: [String: Double]
    public let state: [Double]
    public let residualNorm: Double
    public let iterations: Int
    public let termination: NonlinearSystemTermination
    public let diagnostics: CircuitDiagnostics
}

public struct CircuitDiagnostics: Sendable, Hashable {
    public let finite: Bool
    public let maximumKCLResidual: Double
    public let maximumBranchResidual: Double
}

public struct CircuitModel: Sendable, Hashable {
    public let nodes: [CircuitNode]
    public let referenceNode: Int
    public let devices: [CircuitDevice]
    private let nodeUnknowns: [Int?]
    private let branchUnknowns: [Int?]
    public let unknownNames: [String]

    public init(nodes: [CircuitNode], referenceNode: Int, devices: [CircuitDevice]) throws {
        guard !nodes.isEmpty, nodes.indices.contains(referenceNode) else { throw circuitInvalid("invalid reference node") }
        guard nodes.allSatisfy({ !$0.name.isEmpty && $0.initialVoltage.isFinite }),
              Set(nodes.map(\.name)).count == nodes.count else {
            throw circuitInvalid("node names must be unique and values finite")
        }
        guard devices.allSatisfy({ !$0.name.isEmpty }), Set(devices.map(\.name)).count == devices.count else {
            throw circuitInvalid("device names must be non-empty and unique")
        }
        var nodeUnknowns = [Int?](repeating: nil, count: nodes.count), names: [String] = []
        for node in nodes.indices where node != referenceNode {
            nodeUnknowns[node] = names.count; names.append("V(\(nodes[node].name))")
        }
        var branches = [Int?](repeating: nil, count: devices.count)
        for (index, device) in devices.enumerated() {
            let terminals = device.nodes
            guard nodes.indices.contains(terminals.0), nodes.indices.contains(terminals.1) else { throw circuitInvalid("device node is out of range") }
            switch device {
            case .resistor(_, _, _, let value): guard value.isFinite && value > 0 else { throw circuitInvalid("resistance must be positive") }
            case .capacitor(_, _, _, let value): guard value.isFinite && value > 0 else { throw circuitInvalid("capacitance must be positive") }
            case .inductor(_, _, _, let value, let current): guard value.isFinite && value > 0 && current.isFinite else { throw circuitInvalid("invalid inductor") }
            case .currentSource(_, _, _, let source): guard source.isValid else { throw circuitInvalid("invalid source") }
            case .voltageSource(_, _, _, let source, let current): guard source.isValid && current.isFinite else { throw circuitInvalid("invalid voltage source") }
            case .diode(_, _, _, let current, let voltage): guard current.isFinite && current > 0 && voltage.isFinite && voltage > 0 else { throw circuitInvalid("invalid diode") }
            }
            if device.hasBranch { branches[index] = names.count; names.append("I(\(device.name))") }
        }
        guard !names.isEmpty else { throw circuitInvalid("circuit has no unknowns") }
        self.nodes = nodes; self.referenceNode = referenceNode; self.devices = devices
        self.nodeUnknowns = nodeUnknowns; branchUnknowns = branches; unknownNames = names
    }

    public var unknownCount: Int { unknownNames.count }
    public var initialState: [Double] {
        var result = [Double](repeating: 0, count: unknownCount)
        for node in nodes.indices { if let index = nodeUnknowns[node] { result[index] = nodes[node].initialVoltage } }
        for device in devices.indices { if let index = branchUnknowns[device] {
            switch devices[device] { case .inductor(_,_,_,_,let value), .voltageSource(_,_,_,_,let value): result[index] = value; default: break }
        }}
        return result
    }
    public var zeroDerivative: [Double] { [Double](repeating: 0, count: unknownCount) }

    public func nodeVoltages(for state: [Double]) throws -> [Double] {
        guard state.count == unknownCount else { throw circuitInvalid("invalid circuit state") }
        return nodeUnknowns.map { $0.map { state[$0] } ?? 0 }
    }

    public func assemble(time: Double, state: [Double], derivative: [Double]) throws -> EngineeringAssembly {
        try assemble(time: time, state: state, derivative: derivative, transient: true)
    }
    public func daeEvaluation(time: Double, state: [Double], derivative: [Double]) throws -> DAEEvaluation {
        try assemble(time: time, state: state, derivative: derivative).daeEvaluation()
    }

    public func transient(from start: Double, to end: Double,
                          initialState: [Double], initialDerivative: [Double],
                          options: TimeIntegrationOptions = .init()) throws -> TimeIntegrationResult {
        try TimeIntegrator.integrateDAE(from: start, to: end,
                                        initialState: initialState,
                                        initialDerivative: initialDerivative,
                                        options: options) { time, state, derivative in
            try daeEvaluation(time: time, state: state, derivative: derivative)
        }
    }

    public func dcOperatingPoint(initial: [Double]? = nil,
                                 options: NonlinearSystemOptions = .init()) throws -> CircuitOperatingPoint {
        let start = initial ?? initialState
        guard start.count == unknownCount else { throw circuitInvalid("invalid DC initial state") }
        let zero = zeroDerivative
        let solved = try NonlinearSystemSolver.solve(initial: start, options: options) { state in
            let assembly = try assemble(time: 0, state: state, derivative: zero, transient: false)
            return .init(residuals: assembly.residuals,
                         jacobian: circuitDense(assembly.jacobianState))
        }
        var currents: [String: Double] = [:]
        for device in devices.indices { if let index = branchUnknowns[device] { currents[devices[device].name] = solved.point[index] } }
        let finalAssembly = try assemble(time: 0, state: solved.point, derivative: zero, transient: false)
        let diagnostics = diagnostics(for: finalAssembly.residuals)
        return .init(nodeVoltages: try nodeVoltages(for: solved.point), branchCurrents: currents,
                     state: solved.point, residualNorm: solved.residualNorm,
                     iterations: solved.iterations, termination: solved.termination,
                     diagnostics: diagnostics)
    }

    private func diagnostics(for residuals: [Double]) -> CircuitDiagnostics {
        let nodeEquations = nodes.count - 1
        func maximum(_ values: ArraySlice<Double>) -> Double {
            values.reduce(0) { max($0, abs($1)) }
        }
        return .init(finite: residuals.allSatisfy(\.isFinite),
                     maximumKCLResidual: maximum(residuals[..<nodeEquations]),
                     maximumBranchResidual: maximum(residuals[nodeEquations...]))
    }

    private func assemble(time: Double, state: [Double], derivative: [Double], transient: Bool) throws -> EngineeringAssembly {
        guard time.isFinite, state.count == unknownCount, derivative.count == unknownCount,
              state.allSatisfy(\.isFinite), derivative.allSatisfy(\.isFinite) else { throw circuitInvalid("invalid circuit evaluation point") }
        var residual = [Double](repeating: 0, count: unknownCount)
        var jy = [[Double]](repeating: [Double](repeating: 0, count: unknownCount), count: unknownCount)
        var jyd = jy
        for (deviceIndex, device) in devices.enumerated() {
            let terminals = device.nodes, p = nodeUnknowns[terminals.0], m = nodeUnknowns[terminals.1]
            let voltage = circuitValue(state, p) - circuitValue(state, m)
            let voltageDerivative = circuitValue(derivative, p) - circuitValue(derivative, m)
            switch device {
            case .resistor(_, _, _, let resistance): circuitStampTwoTerminal(p,m,voltage/resistance,1/resistance,0,&residual,&jy,&jyd)
            case .capacitor(_, _, _, let capacitance): circuitStampTwoTerminal(p,m,transient ? capacitance*voltageDerivative : 0,0,transient ? capacitance : 0,&residual,&jy,&jyd)
            case .currentSource(_, _, _, let source): circuitStampCurrent(p,m,source.value(at: time, transient: transient),&residual)
            case .diode(_, _, _, let saturation, let thermal): let exponential=exp(voltage/thermal); guard exponential.isFinite else { throw circuitInvalid("diode exponential overflow") }; circuitStampTwoTerminal(p,m,saturation*(exponential-1),saturation*exponential/thermal,0,&residual,&jy,&jyd)
            case .voltageSource(_, _, _, let source, _): let branch=branchUnknowns[deviceIndex]!; circuitStampBranch(p,m,branch,state[branch],&residual,&jy); residual[branch] += voltage-source.value(at: time, transient: transient); circuitStampVoltage(p,m,branch,1,&jy)
            case .inductor(_, _, _, let inductance, _): let branch=branchUnknowns[deviceIndex]!; circuitStampBranch(p,m,branch,state[branch],&residual,&jy); residual[branch] += voltage-(transient ? inductance*derivative[branch] : 0); circuitStampVoltage(p,m,branch,1,&jy); if transient { jyd[branch][branch] -= inductance }
            }
        }
        guard residual.allSatisfy(\.isFinite), jy.flatMap({$0}).allSatisfy(\.isFinite), jyd.flatMap({$0}).allSatisfy(\.isFinite) else { throw circuitInvalid("circuit assembly produced non-finite values") }
        return .init(residuals: residual, jacobianState: try circuitSparse(jy),
                     jacobianDerivative: try circuitSparse(jyd),
                     parameterJacobian: try SparseMatrix(rows: unknownCount, cols: 0,
                                                         rowPointers: [Int](repeating: 0, count: unknownCount+1), columnIndices: [], values: []))
    }
}

private func circuitValue(_ values:[Double],_ index:Int?)->Double{index.map{values[$0]} ?? 0}
private func circuitStampCurrent(_ p:Int?,_ m:Int?,_ current:Double,_ residual:inout[Double]){if let p{residual[p]+=current};if let m{residual[m]-=current}}
private func circuitStampTwoTerminal(_ p:Int?,_ m:Int?,_ current:Double,_ g:Double,_ c:Double,_ residual:inout[Double],_ jy:inout[[Double]],_ jyd:inout[[Double]]){circuitStampCurrent(p,m,current,&residual);for(row,sign)in[(p,1.0),(m,-1.0)]{if let row{if let p{jy[row][p]+=sign*g;jyd[row][p]+=sign*c};if let m{jy[row][m]-=sign*g;jyd[row][m]-=sign*c}}}}
private func circuitStampBranch(_ p:Int?,_ m:Int?,_ branch:Int,_ current:Double,_ residual:inout[Double],_ jy:inout[[Double]]){circuitStampCurrent(p,m,current,&residual);if let p{jy[p][branch]+=1};if let m{jy[m][branch]-=1}}
private func circuitStampVoltage(_ p:Int?,_ m:Int?,_ row:Int,_ factor:Double,_ jy:inout[[Double]]){if let p{jy[row][p]+=factor};if let m{jy[row][m]-=factor}}
private func circuitSparse(_ matrix:[[Double]])throws->SparseMatrix<Double>{try SparseMatrix(rows:matrix.count,cols:matrix.first?.count ?? 0,entries:matrix.enumerated().flatMap{row,values in values.enumerated().compactMap{column,value in value == 0 ? nil : .init(row:row,column:column,value:value)}})}
private func circuitDense(_ matrix:SparseMatrix<Double>)->[[Double]]{var result=[[Double]](repeating:[Double](repeating:0,count:matrix.cols),count:matrix.rows);for row in 0..<matrix.rows{for index in matrix.csrRowPointers[row]..<matrix.csrRowPointers[row+1]{result[row][matrix.csrColumnIndices[index]]=matrix.csrValues[index]}};return result}
private func circuitInvalid(_ message:String)->NonlinearOptimizationError{.invalidConfiguration(message)}
