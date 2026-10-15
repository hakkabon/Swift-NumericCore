import Foundation

public struct SpiceDiagnostic: Sendable, Hashable {
    public let line: Int
    public let message: String
}

public struct SpiceNetlistError: Error, CustomStringConvertible, Sendable, Hashable {
    public let diagnostics: [SpiceDiagnostic]
    public var description: String {
        guard let first = diagnostics.first else { return "invalid SPICE netlist" }
        return "SPICE line \(first.line): \(first.message)"
    }
}

public enum SpiceACScale: Sendable, Hashable { case linear, decade, octave }

public struct SpiceACAnalysis: Sendable, Hashable {
    public let scale: SpiceACScale
    public let points: Int
    public let start: Double
    public let stop: Double

    public var frequencies: [Double] {
        guard points > 0 else { return [] }
        if start == stop { return [start] }
        switch scale {
        case .linear:
            guard points > 1 else { return [start] }
            return (0..<points).map { start + (stop - start) * Double($0) / Double(points - 1) }
        case .decade, .octave:
            let base: Double = scale == .decade ? 10 : 2
            let intervals = Int(ceil(log(stop / start) / log(base) * Double(points)))
            return (0...intervals).map { min(start * pow(base, Double($0) / Double(points)), stop) }
        }
    }
}

public enum SpiceAnalysis: Sendable, Hashable {
    case operatingPoint
    case transient(step: Double, stop: Double, start: Double)
    case ac(SpiceACAnalysis)
}

public struct ParsedSpiceNetlist: Sendable, Hashable {
    public let title: String?
    public let circuit: CircuitModel
    public let analyses: [SpiceAnalysis]
    public let acExcitations: [CircuitACExcitation]
    public let warnings: [SpiceDiagnostic]
}

private enum SpiceModel {
    case diode(saturation: Double, ideality: Double)
    case nmos(beta: Double, threshold: Double, lambda: Double)
}
private struct SpiceSourceSpec { let source: CircuitSource; let ac: (Double, Double)? }

public enum SpiceNetlist {
    public static func parse(_ source: String) throws -> ParsedSpiceNetlist {
        let lines = logicalLines(source)
        guard !lines.isEmpty else { throw spiceError(0, "netlist is empty") }
        var parameters: [String: Double] = [:]
        for (line, text) in lines {
            let fields = tokenize(text)
            if fields.first?.lowercased() == ".param" {
                for (name, value) in try assignments(Array(fields.dropFirst()), line, parameters) {
                    parameters[name] = value
                }
            }
        }
        var models: [String: SpiceModel] = [:]
        for (line, text) in lines {
            let fields = tokenize(text)
            if fields.first?.lowercased() == ".model" {
                let (name, model) = try parseModel(fields, line, parameters)
                guard models.updateValue(model, forKey: name) == nil else {
                    throw spiceError(line, "duplicate model name")
                }
            }
        }

        var nodes = [CircuitNode(name: "0")]
        var nodeMap = ["0": 0, "gnd": 0]
        var devices: [CircuitDevice] = [], deviceNames = Set<String>()
        var analyses: [SpiceAnalysis] = [], excitations: [CircuitACExcitation] = []
        var initialNodes: [String: Double] = [:], warnings: [SpiceDiagnostic] = []
        var title: String?, sawContent = false

        for (line, text) in lines {
            let fields = tokenize(text); guard let first = fields.first else { continue }
            let head = first.lowercased()
            // Classical SPICE reserves the first non-comment line as the title.
            if !sawContent && !head.hasPrefix(".") {
                title = text.trimmingCharacters(in: .whitespaces); sawContent = true; continue
            }
            sawContent = true
            if head.hasPrefix(".") {
                switch head {
                case ".param", ".model", ".end": break
                case ".op": analyses.append(.operatingPoint)
                case ".tran": analyses.append(try parseTransient(fields, line, parameters))
                case ".ac": analyses.append(.ac(try parseAC(fields, line, parameters)))
                case ".ic": try parseInitialConditions(Array(fields.dropFirst()), line,
                                                        parameters, &initialNodes)
                case ".include", ".lib", ".subckt", ".ends":
                    throw spiceError(line, "unsupported structural directive cannot be ignored safely")
                default: warnings.append(.init(line: line,
                    message: "ignored unsupported directive \(first)"))
                }
                continue
            }
            guard deviceNames.insert(head).inserted else { throw spiceError(line, "duplicate device name") }
            guard let designator = first.first?.uppercased().first else { continue }
            func require(_ count: Int) throws {
                if fields.count < count { throw spiceError(line, "too few element fields") }
            }
            switch designator {
            case "R", "C", "L":
                try require(4)
                let p = spiceNode(fields[1], &nodes, &nodeMap), n = spiceNode(fields[2], &nodes, &nodeMap)
                let value = try parseValue(fields[3], line, parameters)
                let initial = try optionValue(Array(fields.dropFirst(4)), "ic", line, parameters) ?? 0
                if designator == "R" { devices.append(.resistor(name: first, positive: p, negative: n, resistance: value)) }
                else if designator == "C" { devices.append(.capacitor(name: first, positive: p, negative: n, capacitance: value)) }
                else { devices.append(.inductor(name: first, positive: p, negative: n,
                                                inductance: value, initialCurrent: initial)) }
            case "V", "I":
                try require(4)
                let p = spiceNode(fields[1], &nodes, &nodeMap), n = spiceNode(fields[2], &nodes, &nodeMap)
                let specification = try parseSource(Array(fields.dropFirst(3)), line, parameters)
                if let ac = specification.ac {
                    excitations.append(.init(deviceName: first, magnitude: ac.0, phase: ac.1))
                }
                if designator == "V" { devices.append(.voltageSource(name: first, positive: p,
                    negative: n, source: specification.source, initialCurrent: 0)) }
                else { devices.append(.currentSource(name: first, positive: p, negative: n,
                                                     source: specification.source)) }
            case "D":
                try require(4)
                let a = spiceNode(fields[1], &nodes, &nodeMap), c = spiceNode(fields[2], &nodes, &nodeMap)
                guard case .diode(let saturation, let ideality)? = models[fields[3].lowercased()] else {
                    throw spiceError(line, "unknown or non-diode model")
                }
                devices.append(.diode(name: first, anode: a, cathode: c,
                                      saturationCurrent: saturation, thermalVoltage: 0.02585 * ideality))
            case "G", "E":
                try require(6)
                let p = spiceNode(fields[1], &nodes, &nodeMap), n = spiceNode(fields[2], &nodes, &nodeMap)
                let cp = spiceNode(fields[3], &nodes, &nodeMap), cn = spiceNode(fields[4], &nodes, &nodeMap)
                let gain = try parseValue(fields[5], line, parameters)
                if designator == "G" { devices.append(.voltageControlledCurrentSource(name: first,
                    positive: p, negative: n, controlPositive: cp, controlNegative: cn,
                    transconductance: gain)) }
                else { devices.append(.voltageControlledVoltageSource(name: first, positive: p,
                    negative: n, controlPositive: cp, controlNegative: cn, gain: gain,
                    initialCurrent: 0)) }
            case "M":
                try require(6)
                let d = spiceNode(fields[1], &nodes, &nodeMap), g = spiceNode(fields[2], &nodes, &nodeMap)
                let s = spiceNode(fields[3], &nodes, &nodeMap), b = spiceNode(fields[4], &nodes, &nodeMap)
                guard b == s else { throw spiceError(line, "level-1 MOS body must be tied to source") }
                guard case .nmos(let beta, let threshold, let lambda)? = models[fields[5].lowercased()] else {
                    throw spiceError(line, "unknown or non-NMOS model")
                }
                devices.append(.nmosLevel1(name: first, drain: d, gate: g, source: s,
                    transconductance: beta, threshold: threshold, channelLengthModulation: lambda))
            default: throw spiceError(line, "unsupported element designator")
            }
        }
        for (name, voltage) in initialNodes {
            guard let index = nodeMap[name] else { throw spiceError(0, ".IC references unknown node \(name)") }
            nodes[index] = .init(name: nodes[index].name, initialVoltage: voltage)
        }
        do {
            return .init(title: title, circuit: try CircuitModel(nodes: nodes, referenceNode: 0,
                devices: devices), analyses: analyses, acExcitations: excitations, warnings: warnings)
        } catch { throw spiceError(0, String(describing: error)) }
    }
}

private func logicalLines(_ source: String) -> [(Int, String)] {
    var result: [(Int, String)] = []
    for (offset, raw) in source.components(separatedBy: .newlines).enumerated() {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("*") { continue }
        let text = String(trimmed.split(separator: "$", maxSplits: 1,
                                        omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("+") {
            if !result.isEmpty { result[result.count - 1].1 += " " + text.dropFirst().trimmingCharacters(in: .whitespaces) }
        } else if !text.isEmpty {
            result.append((offset + 1, text))
            if text.lowercased() == ".end" { break }
        }
    }
    return result
}
private func tokenize(_ text: String) -> [String] {
    var result: [String] = [], current = ""
    for character in text {
        if character.isWhitespace || "(),=".contains(character) {
            if !current.isEmpty { result.append(current); current = "" }
        } else { current.append(character) }
    }
    if !current.isEmpty { result.append(current) }; return result
}
private func spiceNode(_ name: String, _ nodes: inout [CircuitNode],
                       _ map: inout [String: Int]) -> Int {
    let key = name.lowercased(); if key == "0" || key == "gnd" { return 0 }
    if let index = map[key] { return index }
    let index = nodes.count; map[key] = index; nodes.append(.init(name: name)); return index
}
private func parseValue(_ token: String, _ line: Int,
                        _ parameters: [String: Double]) throws -> Double {
    let stripped = token.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
    if let value = parameters[stripped.lowercased()] { return value }
    var split = stripped.endIndex, base: Double?
    while split > stripped.startIndex {
        if let value = Double(stripped[..<split]) { base = value; break }
        split = stripped.index(before: split)
    }
    guard let base else { throw spiceError(line, "invalid numeric value \(token)") }
    let suffix = stripped[split...].lowercased()
    let multiplier: Double
    if suffix.hasPrefix("meg") { multiplier = 1e6 }
    else { switch suffix.first {
    case nil: multiplier = 1
    case "t": multiplier = 1e12; case "g": multiplier = 1e9; case "k": multiplier = 1e3
    case "m": multiplier = 1e-3; case "u": multiplier = 1e-6; case "n": multiplier = 1e-9
    case "p": multiplier = 1e-12; case "f": multiplier = 1e-15
    default: throw spiceError(line, "unknown numeric suffix in \(token)")
    }}
    let result = base * multiplier
    guard result.isFinite else { throw spiceError(line, "numeric value is not finite") }; return result
}
private func assignments(_ fields: [String], _ line: Int,
                         _ parameters: [String: Double]) throws -> [(String, Double)] {
    guard fields.count.isMultiple(of: 2) else { throw spiceError(line, "expected name=value assignments") }
    return try stride(from: 0, to: fields.count, by: 2).map {
        (fields[$0].lowercased(), try parseValue(fields[$0 + 1], line, parameters))
    }
}
private func optionValue(_ fields: [String], _ name: String, _ line: Int,
                         _ parameters: [String: Double]) throws -> Double? {
    guard fields.count >= 2 else { return nil }
    for index in 0..<(fields.count - 1) where fields[index].lowercased() == name {
        return try parseValue(fields[index + 1], line, parameters)
    }
    return nil
}
private func parseModel(_ fields: [String], _ line: Int,
                        _ parameters: [String: Double]) throws -> (String, SpiceModel) {
    guard fields.count >= 3 else { throw spiceError(line, "incomplete .MODEL directive") }
    let options = Dictionary(uniqueKeysWithValues: try assignments(Array(fields.dropFirst(3)), line, parameters))
    let model: SpiceModel
    switch fields[2].lowercased() {
    case "d", "diode": model = .diode(saturation: options["is"] ?? 1e-14,
                                       ideality: options["n"] ?? 1)
    case "nmos": model = .nmos(beta: options["kp"] ?? 1e-3,
                               threshold: options["vto"] ?? 0.7,
                               lambda: options["lambda"] ?? 0)
    default: throw spiceError(line, "only diode and NMOS level-1 models are supported")
    }
    return (fields[1].lowercased(), model)
}
private func parseSource(_ fields: [String], _ line: Int,
                         _ parameters: [String: Double]) throws -> SpiceSourceSpec {
    var dc = 0.0, waveform: CircuitWaveform?, ac: (Double, Double)?, index = 0
    let keywords = ["dc", "ac", "sin", "pulse"]
    if !fields.isEmpty && !keywords.contains(fields[0].lowercased()) {
        dc = try parseValue(fields[0], line, parameters); index = 1
    }
    while index < fields.count {
        switch fields[index].lowercased() {
        case "dc":
            index += 1; guard index < fields.count else { throw spiceError(line, "DC source value is missing") }
            dc = try parseValue(fields[index], line, parameters); index += 1
        case "ac":
            index += 1; guard index < fields.count else { throw spiceError(line, "AC magnitude is missing") }
            let magnitude = try parseValue(fields[index], line, parameters); index += 1
            var phase = 0.0
            if index < fields.count && !["dc", "sin", "pulse"].contains(fields[index].lowercased()) {
                phase = try parseValue(fields[index], line, parameters) * .pi / 180; index += 1
            }
            ac = (magnitude, phase)
        case "sin":
            guard index + 3 < fields.count else { throw spiceError(line, "SIN requires offset, amplitude, and frequency") }
            let offset = try parseValue(fields[index+1], line, parameters)
            let amplitude = try parseValue(fields[index+2], line, parameters)
            let frequency = try parseValue(fields[index+3], line, parameters)
            let phase = index + 4 < fields.count ? try parseValue(fields[index+4], line, parameters) * .pi / 180 : 0
            waveform = .sinusoidal(offset: offset, amplitude: amplitude, frequency: frequency, phase: phase)
            index = fields.count
        case "pulse":
            guard index + 7 < fields.count else { throw spiceError(line, "PULSE requires seven values") }
            let value: (Int) throws -> Double = { try parseValue(fields[index + $0], line, parameters) }
            waveform = .pulse(low: try value(1), high: try value(2), delay: try value(3),
                rise: try value(4), fall: try value(5), width: try value(6), period: try value(7))
            index += 8
        default: throw spiceError(line, "unsupported source specification")
        }
    }
    return .init(source: .init(dcValue: dc, transientWaveform: waveform), ac: ac)
}
private func parseTransient(_ fields: [String], _ line: Int,
                            _ parameters: [String: Double]) throws -> SpiceAnalysis {
    guard fields.count >= 3 else { throw spiceError(line, ".TRAN requires step and stop") }
    let step = try parseValue(fields[1], line, parameters), stop = try parseValue(fields[2], line, parameters)
    let start = fields.count > 3 ? try parseValue(fields[3], line, parameters) : 0
    guard step > 0, stop > start else { throw spiceError(line, "invalid .TRAN interval") }
    return .transient(step: step, stop: stop, start: start)
}
private func parseAC(_ fields: [String], _ line: Int,
                     _ parameters: [String: Double]) throws -> SpiceACAnalysis {
    guard fields.count >= 5 else { throw spiceError(line, ".AC requires scale, points, start, and stop") }
    let scale: SpiceACScale
    switch fields[1].lowercased() { case "lin": scale = .linear; case "dec": scale = .decade
    case "oct": scale = .octave; default: throw spiceError(line, "unknown .AC scale") }
    let rawPoints = try parseValue(fields[2], line, parameters), points = Int(rawPoints)
    let start = try parseValue(fields[3], line, parameters), stop = try parseValue(fields[4], line, parameters)
    guard points > 0, rawPoints == Double(points), start > 0, stop >= start else {
        throw spiceError(line, "invalid .AC sweep")
    }
    return .init(scale: scale, points: points, start: start, stop: stop)
}
private func parseInitialConditions(_ fields: [String], _ line: Int,
                                    _ parameters: [String: Double],
                                    _ result: inout [String: Double]) throws {
    var index = 0
    while index < fields.count {
        guard fields[index].lowercased() == "v", index + 2 < fields.count else {
            throw spiceError(line, "expected .IC V(node)=value")
        }
        result[fields[index+1].lowercased()] = try parseValue(fields[index+2], line, parameters)
        index += 3
    }
}
private func spiceError(_ line: Int, _ message: String) -> SpiceNetlistError {
    .init(diagnostics: [.init(line: line, message: message)])
}
