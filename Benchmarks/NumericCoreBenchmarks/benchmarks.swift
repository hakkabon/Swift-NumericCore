import Foundation
import NumericCoreOptimization

struct BenchmarkRecord: Codable {
    let name: String
    let size: Int
    let iterations: Int
    let nanosecondsPerIteration: Double
}

@main
enum NumericCoreBenchmarks {
    static func main() throws {
        let iterations = max(1, Int(ProcessInfo.processInfo.environment["NC_BENCH_ITERATIONS"] ?? "20") ?? 20)
        var records: [BenchmarkRecord] = []
        for size in [100, 1_000, 10_000] {
            let problem = try bandedProblem(size: size)
            let workspace = try SparseLinearWorkspace(problem: problem)
            let point = [Double](repeating: 0.5, count: size)
            records.append(try measure(name: "sparse_row_activity", size: size,
                                       iterations: iterations) {
                _ = try workspace.rowActivity(point)
            })
            records.append(try measure(name: "presolve", size: size, iterations: iterations) {
                _ = try LinearModelPresolver.presolve(problem)
            })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(records), as: UTF8.self))
    }

    private static func measure(name: String, size: Int, iterations: Int,
                                operation: () throws -> Void) rethrows -> BenchmarkRecord {
        try operation()
        let start = ContinuousClock.now
        for _ in 0..<iterations { try operation() }
        let duration = start.duration(to: .now)
        let components = duration.components
        let nanoseconds = Double(components.seconds) * 1e9
            + Double(components.attoseconds) / 1e9
        return .init(name: name, size: size, iterations: iterations,
                     nanosecondsPerIteration: nanoseconds / Double(iterations))
    }

    private static func bandedProblem(size: Int) throws -> SparseLinearProblem {
        var pointers = [0], columns: [Int] = [], values: [Double] = []
        for row in 0..<size {
            columns.append(row); values.append(2)
            if row + 1 < size { columns.append(row + 1); values.append(-1) }
            pointers.append(values.count)
        }
        return try .init(
            objective: [Double](repeating: 1, count: size), rows: size, columns: size,
            rowPointers: pointers, columnIndices: columns, values: values,
            rowBounds: [ParameterBound](repeating: .init(upper: 3), count: size),
            variableBounds: [ParameterBound](repeating: .init(lower: 0, upper: 1), count: size))
    }
}
