import Foundation

public struct ModelPresolveOptions: Sendable, Hashable {
    public var maxPasses: Int; public var tolerance: Double
    public init(maxPasses: Int = 8, tolerance: Double = 1e-10) {
        self.maxPasses = maxPasses; self.tolerance = tolerance
    }
}
public enum ModelPresolveStatus: Sendable, Hashable { case reduced, solved, infeasible }
public struct ModelPresolveReport: Sendable, Hashable {
    public let passes: Int; public let fixedVariables: Int; public let removedRows: Int
    public let tightenedBounds: Int; public let originalNonzeros: Int; public let reducedNonzeros: Int
}
public struct PresolvedLinearProblem: Sendable, Hashable {
    public let problem: SparseLinearProblem?; public let status: ModelPresolveStatus
    public let activeVariables: [Int]; public let fixedValues: [Double?]
    public let keptRows: [Int]; public let objectiveOffset: Double
    public let report: ModelPresolveReport
    public func restorePoint(_ reduced: [Double]) throws -> [Double] {
        guard reduced.count == activeVariables.count else {
            throw NonlinearOptimizationError.invalidConfiguration("postsolve point dimension mismatch")
        }
        var point = fixedValues.map { $0 ?? 0 }
        for (index, original) in activeVariables.enumerated() { point[original] = reduced[index] }
        return point
    }
    public func restoreObjective(_ reduced: Double) -> Double { reduced + objectiveOffset }
}

public enum LinearModelPresolver {
    public static func presolve(_ problem: SparseLinearProblem,
                               options: ModelPresolveOptions = .init()) throws
        -> PresolvedLinearProblem {
        try problem.validate()
        guard options.maxPasses > 0, options.tolerance.isFinite, options.tolerance >= 0 else {
            throw NonlinearOptimizationError.invalidConfiguration("invalid presolve options")
        }
        var bounds = problem.variableBounds
        var removed = [Bool](repeating: false, count: problem.rows)
        var tightened = 0, passes = 0, infeasible = false
        for pass in 0..<options.maxPasses {
            passes = pass + 1; let before = tightened
            for row in 0..<problem.rows where !removed[row] {
                let entries = rowEntries(problem, row)
                let range = activityInterval(entries, bounds)
                let target = problem.rowBounds[row]
                if target.lower.map({ range.1 < $0 - options.tolerance }) ?? false
                    || target.upper.map({ range.0 > $0 + options.tolerance }) ?? false {
                    infeasible = true; break
                }
                if (target.lower.map { range.0 >= $0 - options.tolerance } ?? true)
                    && (target.upper.map { range.1 <= $0 + options.tolerance } ?? true) {
                    removed[row] = true; continue
                }
                var free: (Int, Double)?, fixedSum = 0.0, multiple = false
                for (column, coefficient) in entries {
                    if let value = fixed(bounds[column], options.tolerance) {
                        fixedSum += coefficient * value
                    } else if free == nil { free = (column, coefficient) }
                    else { multiple = true; break }
                }
                if !multiple, let (column, coefficient) = free {
                    var next = bounds[column]
                    if let lower = target.lower {
                        let value = (lower - fixedSum) / coefficient
                        if coefficient > 0 { next.lower = max(next.lower ?? -.infinity, value) }
                        else { next.upper = min(next.upper ?? .infinity, value) }
                    }
                    if let upper = target.upper {
                        let value = (upper - fixedSum) / coefficient
                        if coefficient > 0 { next.upper = min(next.upper ?? .infinity, value) }
                        else { next.lower = max(next.lower ?? -.infinity, value) }
                    }
                    if problem.isInteger[column] {
                        next.lower = next.lower.map { ceil($0 - options.tolerance) }
                        next.upper = next.upper.map { floor($0 + options.tolerance) }
                    }
                    if (next.lower ?? -.infinity) > (next.upper ?? .infinity) + options.tolerance {
                        infeasible = true; break
                    }
                    if next != bounds[column] {
                        tightened += (next.lower != bounds[column].lower ? 1 : 0)
                            + (next.upper != bounds[column].upper ? 1 : 0)
                        bounds[column] = next
                    }
                } else if !multiple, free == nil,
                          (target.lower.map { fixedSum < $0 - options.tolerance } ?? false
                           || target.upper.map { fixedSum > $0 + options.tolerance } ?? false) {
                    infeasible = true; break
                }
            }
            if infeasible || tightened == before { break }
        }
        if infeasible {
            return .init(problem: nil, status: .infeasible, activeVariables: [],
                         fixedValues: [Double?](repeating: nil, count: problem.columns), keptRows: [],
                         objectiveOffset: 0,
                         report: .init(passes: passes, fixedVariables: 0, removedRows: 0,
                                       tightenedBounds: tightened,
                                       originalNonzeros: problem.values.count, reducedNonzeros: 0))
        }
        let fixedValues = bounds.map { fixed($0, options.tolerance) }
        let active = bounds.indices.filter { fixedValues[$0] == nil }
        var remap = [Int?](repeating: nil, count: problem.columns)
        for (index, original) in active.enumerated() { remap[original] = index }
        var shifted = [Double](repeating: 0, count: problem.rows)
        var candidateRows = [[(Int, Double)]](repeating: [], count: problem.rows)
        for row in 0..<problem.rows { for (column, coefficient) in rowEntries(problem, row) {
            if let value = fixedValues[column] { shifted[row] += coefficient * value }
            else { candidateRows[row].append((remap[column]!, coefficient)) }
        }}
        let activeBounds = active.map { bounds[$0] }
        var kept: [Int] = [], finalRows: [[(Int, Double)]] = [], finalBounds: [ParameterBound] = []
        for row in 0..<problem.rows where !removed[row] {
            let adjusted = ParameterBound(
                lower: problem.rowBounds[row].lower.map { $0 - shifted[row] },
                upper: problem.rowBounds[row].upper.map { $0 - shifted[row] })
            let range = activityInterval(candidateRows[row], activeBounds)
            if (adjusted.lower.map { range.0 >= $0 - options.tolerance } ?? true)
                && (adjusted.upper.map { range.1 <= $0 + options.tolerance } ?? true) { continue }
            kept.append(row); finalRows.append(candidateRows[row]); finalBounds.append(adjusted)
        }
        var pointers = [0], columns: [Int] = [], values: [Double] = []
        for row in finalRows { for entry in row { columns.append(entry.0); values.append(entry.1) }
            pointers.append(values.count) }
        let offset = problem.objective.indices.reduce(0.0) { total, index in
            total + (fixedValues[index].map { problem.objective[index] * $0 } ?? 0)
        }
        let reduced: SparseLinearProblem? = active.isEmpty ? nil : try .init(
            objective: active.map { problem.objective[$0] }, rows: finalRows.count,
            columns: active.count, rowPointers: pointers, columnIndices: columns, values: values,
            rowBounds: finalBounds, variableBounds: activeBounds,
            isInteger: active.map { problem.isInteger[$0] })
        return .init(problem: reduced, status: active.isEmpty ? .solved : .reduced,
                     activeVariables: active, fixedValues: fixedValues, keptRows: kept,
                     objectiveOffset: offset,
                     report: .init(passes: passes, fixedVariables: problem.columns - active.count,
                                   removedRows: problem.rows - finalRows.count,
                                   tightenedBounds: tightened,
                                   originalNonzeros: problem.values.count,
                                   reducedNonzeros: values.count))
    }
}

private func rowEntries(_ problem: SparseLinearProblem, _ row: Int) -> [(Int, Double)] {
    (problem.rowPointers[row]..<problem.rowPointers[row + 1]).map {
        (problem.columnIndices[$0], problem.values[$0])
    }
}
private func fixed(_ bound: ParameterBound, _ tolerance: Double) -> Double? {
    guard let lower = bound.lower, let upper = bound.upper,
          abs(upper - lower) <= tolerance else { return nil }
    return 0.5 * (lower + upper)
}
private func activityInterval(_ entries: [(Int, Double)], _ bounds: [ParameterBound])
    -> (Double, Double) {
    var lower = 0.0, upper = 0.0
    for (column, coefficient) in entries {
        let bound = bounds[column]
        if coefficient >= 0 {
            lower += coefficient * (bound.lower ?? -.infinity)
            upper += coefficient * (bound.upper ?? .infinity)
        } else {
            lower += coefficient * (bound.upper ?? .infinity)
            upper += coefficient * (bound.lower ?? -.infinity)
        }
    }
    return (lower, upper)
}
