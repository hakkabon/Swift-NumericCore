import Foundation
import NumericCore
import NumericCoreAMPL

enum ValidationCommandError: Error, CustomStringConvertible {
    case unknownTier(String)
    case failed(Int)
    case invalidManifest([String])

    var description: String {
        switch self {
        case .unknownTier(let tier): return "unknown validation tier: \(tier)"
        case .failed(let count): return "numerical validation failed in \(count) case(s)"
        case .invalidManifest(let issues): return issues.joined(separator: "; ")
        }
    }
}

@main
enum NumericCoreValidationCommand {
    static func main() throws {
        let value = CommandLine.arguments.dropFirst().first ?? "standard"
        guard let tier = ValidationTier(rawValue: value) else {
            throw ValidationCommandError.unknownTier(value)
        }
        let report = try NumericCoreValidationProgram.run().filtered(through: tier)
        let snapshot = report.snapshot(implementation: "swift-numericcore", tier: tier)
        FileHandle.standardOutput.write(try snapshot.jsonData())
        FileHandle.standardOutput.write(Data("\n".utf8))
        guard snapshot.manifestIssues.isEmpty else {
            throw ValidationCommandError.invalidManifest(snapshot.manifestIssues)
        }
        guard report.passed else { throw ValidationCommandError.failed(report.failureCount) }
    }
}
