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

    fileprivate func breakpoints(from start: Double, to end: Double) -> [Double] {
        guard case .pulse(_, _, let delay, let rise, let fall, let width, let period) = self else { return [] }
        let lower = min(start, end), upper = max(start, end)
        var result: [Double] = [], cycle = 0
        while true {
            let base = delay + Double(cycle) * period
            if base > upper { break }
            for point in [base, base + rise, base + rise + width, base + rise + width + fall]
                where point > lower && point < upper { result.append(point) }
            if period == 0 { break }
            cycle += 1
        }
        return result
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
    fileprivate func breakpoints(from start: Double, to end: Double) -> [Double] {
        transientWaveform?.breakpoints(from: start, to: end) ?? []
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
    case voltageControlledCurrentSource(name: String, positive: Int, negative: Int,
                                        controlPositive: Int, controlNegative: Int,
                                        transconductance: Double)
    case voltageControlledVoltageSource(name: String, positive: Int, negative: Int,
                                        controlPositive: Int, controlNegative: Int,
                                        gain: Double, initialCurrent: Double)
    case nmosLevel1(name: String, drain: Int, gate: Int, source: Int,
                    transconductance: Double, threshold: Double,
                    channelLengthModulation: Double)

    public var name: String {
        switch self {
        case .resistor(let name, _, _, _), .capacitor(let name, _, _, _),
             .inductor(let name, _, _, _, _), .currentSource(let name, _, _, _),
             .voltageSource(let name, _, _, _, _), .diode(let name, _, _, _, _),
             .voltageControlledCurrentSource(let name, _, _, _, _, _),
             .voltageControlledVoltageSource(let name, _, _, _, _, _, _),
             .nmosLevel1(let name, _, _, _, _, _, _): return name
        }
    }
    fileprivate var nodes: (Int, Int) {
        switch self {
        case .resistor(_, let p, let n, _), .capacitor(_, let p, let n, _),
             .inductor(_, let p, let n, _, _), .currentSource(_, let p, let n, _),
             .voltageSource(_, let p, let n, _, _): return (p, n)
        case .diode(_, let a, let c, _, _): return (a, c)
        case .voltageControlledCurrentSource(_, let p, let n, _, _, _),
             .voltageControlledVoltageSource(_, let p, let n, _, _, _, _): return (p, n)
        case .nmosLevel1(_, let drain, _, let source, _, _, _): return (drain, source)
        }
    }
    fileprivate var hasBranch: Bool {
        switch self { case .inductor, .voltageSource, .voltageControlledVoltageSource: return true; default: return false }
    }
}

public struct CircuitDCContinuationOptions: Sendable, Hashable {
    public var steps: Int
    public var initialGmin: Double
    public init(steps: Int = 8, initialGmin: Double = 1e-3) {
        self.steps = steps; self.initialGmin = initialGmin
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
    public let continuationSteps: Int
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
            case .voltageControlledCurrentSource(_, _, _, let cp, let cm, _),
                 .voltageControlledVoltageSource(_, _, _, let cp, let cm, _, _):
                guard nodes.indices.contains(cp), nodes.indices.contains(cm) else { throw circuitInvalid("control node is out of range") }
            case .nmosLevel1(_, _, let gate, _, _, _, _):
                guard nodes.indices.contains(gate) else { throw circuitInvalid("MOS gate node is out of range") }
            default: break
            }
            switch device {
            case .resistor(_, _, _, let value): guard value.isFinite && value > 0 else { throw circuitInvalid("resistance must be positive") }
            case .capacitor(_, _, _, let value): guard value.isFinite && value > 0 else { throw circuitInvalid("capacitance must be positive") }
            case .inductor(_, _, _, let value, let current): guard value.isFinite && value > 0 && current.isFinite else { throw circuitInvalid("invalid inductor") }
            case .currentSource(_, _, _, let source): guard source.isValid else { throw circuitInvalid("invalid source") }
            case .voltageSource(_, _, _, let source, let current): guard source.isValid && current.isFinite else { throw circuitInvalid("invalid voltage source") }
            case .diode(_, _, _, let current, let voltage): guard current.isFinite && current > 0 && voltage.isFinite && voltage > 0 else { throw circuitInvalid("invalid diode") }
            case .voltageControlledCurrentSource(_, _, _, _, _, let gm): guard gm.isFinite else { throw circuitInvalid("invalid controlled-source transconductance") }
            case .voltageControlledVoltageSource(_, _, _, _, _, let gain, let current): guard gain.isFinite && current.isFinite else { throw circuitInvalid("invalid controlled voltage source") }
            case .nmosLevel1(_, _, _, _, let beta, let threshold, let modulation): guard beta.isFinite && beta > 0 && threshold.isFinite && modulation.isFinite && modulation >= 0 else { throw circuitInvalid("invalid level-1 NMOS") }
            }
            if device.hasBranch { branches[index] = names.count; names.append("I(\(device.name))") }
        }
        guard !names.isEmpty else { throw circuitInvalid("circuit has no unknowns") }
        self.nodes = nodes; self.referenceNode = referenceNode; self.devices = devices
        self.nodeUnknowns = nodeUnknowns; branchUnknowns = branches; unknownNames = names
    }

    public var unknownCount: Int { unknownNames.count }
    public func nodeUnknownIndex(_ node: Int) throws -> Int? {
        guard nodeUnknowns.indices.contains(node) else { throw circuitInvalid("node is out of range") }
        return nodeUnknowns[node]
    }
    public func branchUnknownIndex(_ device: Int) throws -> Int? {
        guard branchUnknowns.indices.contains(device) else { throw circuitInvalid("device is out of range") }
        return branchUnknowns[device]
    }
    public var initialState: [Double] {
        var result = [Double](repeating: 0, count: unknownCount)
        for node in nodes.indices { if let index = nodeUnknowns[node] { result[index] = nodes[node].initialVoltage } }
        for device in devices.indices { if let index = branchUnknowns[device] {
            switch devices[device] { case .inductor(_,_,_,_,let value), .voltageSource(_,_,_,_,let value), .voltageControlledVoltageSource(_,_,_,_,_,_,let value): result[index] = value; default: break }
        }}
        return result
    }
    public var zeroDerivative: [Double] { [Double](repeating: 0, count: unknownCount) }

    public func nodeVoltages(for state: [Double]) throws -> [Double] {
        guard state.count == unknownCount else { throw circuitInvalid("invalid circuit state") }
        return nodeUnknowns.map { $0.map { state[$0] } ?? 0 }
    }

    public func assemble(time: Double, state: [Double], derivative: [Double]) throws -> EngineeringAssembly {
        try assemble(time: time, state: state, derivative: derivative, transient: true,
                     sourceScale: 1, gmin: 0)
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

    public func transientBreakpoints(from start: Double, to end: Double) throws -> [Double] {
        guard start.isFinite, end.isFinite else { throw circuitInvalid("invalid transient interval") }
        let raw = devices.flatMap { device -> [Double] in
            switch device {
            case .currentSource(_, _, _, let source), .voltageSource(_, _, _, let source, _):
                return source.breakpoints(from: start, to: end)
            default: return []
            }
        }.sorted()
        var unique: [Double] = []
        for point in raw where unique.last.map({ abs(point - $0) > Double.ulpOfOne * max(abs(point), abs($0), 1) }) ?? true {
            unique.append(point)
        }
        return end < start ? Array(unique.reversed()) : unique
    }

    public func dcOperatingPoint(initial: [Double]? = nil,
                                 options: NonlinearSystemOptions = .init()) throws -> CircuitOperatingPoint {
        let start = initial ?? initialState
        return try solveDC(initial: start, options: options, sourceScale: 1,
                           gmin: 0, continuationSteps: 0)
    }

    public func dcOperatingPointContinuation(initial: [Double]? = nil,
                                             options: NonlinearSystemOptions = .init(),
                                             continuation: CircuitDCContinuationOptions = .init()) throws -> CircuitOperatingPoint {
        guard continuation.steps > 0, continuation.initialGmin.isFinite,
              continuation.initialGmin >= 0 else { throw circuitInvalid("invalid DC continuation options") }
        var state = initial ?? initialState
        guard state.count == unknownCount else { throw circuitInvalid("invalid DC initial state") }
        var result: CircuitOperatingPoint?
        for step in 0...continuation.steps {
            let fraction = Double(step) / Double(continuation.steps)
            let gmin = continuation.initialGmin * pow(1 - fraction, 3)
            result = try solveDC(initial: state, options: options, sourceScale: fraction,
                                 gmin: gmin, continuationSteps: step + 1)
            state = result!.state
        }
        return result!
    }

    private func solveDC(initial start: [Double], options: NonlinearSystemOptions,
                         sourceScale: Double, gmin: Double,
                         continuationSteps: Int) throws -> CircuitOperatingPoint {
        guard start.count == unknownCount else { throw circuitInvalid("invalid DC initial state") }
        let zero = zeroDerivative
        let solved = try NonlinearSystemSolver.solve(initial: start, options: options) { state in
            let assembly = try assemble(time: 0, state: state, derivative: zero, transient: false,
                                        sourceScale: sourceScale, gmin: gmin)
            return .init(residuals: assembly.residuals,
                         jacobian: circuitDense(assembly.jacobianState))
        }
        var currents: [String: Double] = [:]
        for device in devices.indices { if let index = branchUnknowns[device] { currents[devices[device].name] = solved.point[index] } }
        let finalAssembly = try assemble(time: 0, state: solved.point, derivative: zero,
                                         transient: false, sourceScale: 1, gmin: 0)
        let diagnostics = diagnostics(for: finalAssembly.residuals)
        return .init(nodeVoltages: try nodeVoltages(for: solved.point), branchCurrents: currents,
                     state: solved.point, residualNorm: solved.residualNorm,
                     iterations: solved.iterations, termination: solved.termination,
                     diagnostics: diagnostics, continuationSteps: continuationSteps)
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

    private func assemble(time: Double, state: [Double], derivative: [Double], transient: Bool,
                          sourceScale: Double, gmin: Double) throws -> EngineeringAssembly {
        guard time.isFinite, state.count == unknownCount, derivative.count == unknownCount,
              state.allSatisfy(\.isFinite), derivative.allSatisfy(\.isFinite),
              sourceScale.isFinite, gmin.isFinite, gmin >= 0 else { throw circuitInvalid("invalid circuit evaluation point") }
        var residual = [Double](repeating: 0, count: unknownCount)
        var jy = [[Double]](repeating: [Double](repeating: 0, count: unknownCount), count: unknownCount)
        var jyd = jy
        for index in nodeUnknowns.compactMap({ $0 }) {
            residual[index] += gmin * state[index]; jy[index][index] += gmin
        }
        for (deviceIndex, device) in devices.enumerated() {
            let terminals = device.nodes, p = nodeUnknowns[terminals.0], m = nodeUnknowns[terminals.1]
            let voltage = circuitValue(state, p) - circuitValue(state, m)
            let voltageDerivative = circuitValue(derivative, p) - circuitValue(derivative, m)
            switch device {
            case .resistor(_, _, _, let resistance): circuitStampTwoTerminal(p,m,voltage/resistance,1/resistance,0,&residual,&jy,&jyd)
            case .capacitor(_, _, _, let capacitance): circuitStampTwoTerminal(p,m,transient ? capacitance*voltageDerivative : 0,0,transient ? capacitance : 0,&residual,&jy,&jyd)
            case .currentSource(_, _, _, let source): circuitStampCurrent(p,m,sourceScale*source.value(at: time, transient: transient),&residual)
            case .diode(_, _, _, let saturation, let thermal): let exponential=exp(voltage/thermal); guard exponential.isFinite else { throw circuitInvalid("diode exponential overflow") }; circuitStampTwoTerminal(p,m,saturation*(exponential-1),saturation*exponential/thermal,0,&residual,&jy,&jyd)
            case .voltageSource(_, _, _, let source, _): let branch=branchUnknowns[deviceIndex]!; circuitStampBranch(p,m,branch,state[branch],&residual,&jy); residual[branch] += voltage-sourceScale*source.value(at: time, transient: transient); circuitStampVoltage(p,m,branch,1,&jy)
            case .inductor(_, _, _, let inductance, _): let branch=branchUnknowns[deviceIndex]!; circuitStampBranch(p,m,branch,state[branch],&residual,&jy); residual[branch] += voltage-(transient ? inductance*derivative[branch] : 0); circuitStampVoltage(p,m,branch,1,&jy); if transient { jyd[branch][branch] -= inductance }
            case .voltageControlledCurrentSource(_, _, _, let controlPositive, let controlNegative, let gm):
                let cp=nodeUnknowns[controlPositive], cm=nodeUnknowns[controlNegative]
                let control=circuitValue(state,cp)-circuitValue(state,cm)
                circuitStampControlledCurrent(p,m,gm*control,[(cp,gm),(cm,-gm)],&residual,&jy)
            case .voltageControlledVoltageSource(_, _, _, let controlPositive, let controlNegative, let gain, _):
                let branch=branchUnknowns[deviceIndex]!, cp=nodeUnknowns[controlPositive], cm=nodeUnknowns[controlNegative]
                circuitStampBranch(p,m,branch,state[branch],&residual,&jy)
                residual[branch] += voltage-gain*(circuitValue(state,cp)-circuitValue(state,cm))
                circuitStampVoltage(p,m,branch,1,&jy); circuitStampVoltage(cp,cm,branch,-gain,&jy)
            case .nmosLevel1(_, _, let gate, _, let beta, let threshold, let modulation):
                let g=nodeUnknowns[gate], vgs=circuitValue(state,g)-circuitValue(state,m)
                let model=circuitNMOSLevel1(vgs:vgs,vds:voltage,beta:beta,threshold:threshold,lambda:modulation)
                circuitStampControlledCurrent(p,m,model.current,[(p,model.gds),(g,model.gm),(m,-model.gds-model.gm)],&residual,&jy)
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
private func circuitStampControlledCurrent(_ p:Int?,_ m:Int?,_ current:Double,_ derivatives:[(Int?,Double)],_ residual:inout[Double],_ jy:inout[[Double]]){circuitStampCurrent(p,m,current,&residual);for(row,sign)in[(p,1.0),(m,-1.0)]{if let row{for(column,derivative)in derivatives{if let column{jy[row][column]+=sign*derivative}}}}}
private func circuitStampVoltage(_ p:Int?,_ m:Int?,_ row:Int,_ factor:Double,_ jy:inout[[Double]]){if let p{jy[row][p]+=factor};if let m{jy[row][m]-=factor}}
private func circuitNMOSLevel1(vgs:Double,vds:Double,beta:Double,threshold:Double,lambda:Double)->(current:Double,gm:Double,gds:Double){let overdrive=vgs-threshold;if overdrive<=0{return(0,0,0)};if vds<overdrive{let base=beta*(overdrive*vds-0.5*vds*vds),modulation=1+lambda*vds;return(base*modulation,beta*vds*modulation,beta*(overdrive-vds)*modulation+lambda*base)};let base=0.5*beta*overdrive*overdrive;return(base*(1+lambda*vds),beta*overdrive*(1+lambda*vds),lambda*base)}
private func circuitSparse(_ matrix:[[Double]])throws->SparseMatrix<Double>{try SparseMatrix(rows:matrix.count,cols:matrix.first?.count ?? 0,entries:matrix.enumerated().flatMap{row,values in values.enumerated().compactMap{column,value in value == 0 ? nil : .init(row:row,column:column,value:value)}})}
private func circuitDense(_ matrix:SparseMatrix<Double>)->[[Double]]{var result=[[Double]](repeating:[Double](repeating:0,count:matrix.cols),count:matrix.rows);for row in 0..<matrix.rows{for index in matrix.csrRowPointers[row]..<matrix.csrRowPointers[row+1]{result[row][matrix.csrColumnIndices[index]]=matrix.csrValues[index]}};return result}
private func circuitInvalid(_ message:String)->NonlinearOptimizationError{.invalidConfiguration(message)}
