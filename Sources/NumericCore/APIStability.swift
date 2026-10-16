/// Stability level attached to a NumericCore capability.
///
/// Stability describes the public API contract, not the numerical quality of
/// an implementation. Experimental capabilities may still be well tested.
public enum NumericCoreAPIStability: String, Sendable, Hashable, Codable, CaseIterable {
    /// Names and semantics are intended to remain source compatible through 1.x.
    case stable
    /// The capability is supported, but its public surface may still be refined before 1.0.
    case provisional
    /// The capability is available for evaluation without a compatibility promise.
    case experimental
}

/// A stable, machine-readable description of one NumericCore capability.
public struct NumericCoreCapability: Sendable, Hashable, Codable {
    public let identifier: String
    public let stability: NumericCoreAPIStability
    public let contractVersion: Int

    public init(identifier: String, stability: NumericCoreAPIStability,
                contractVersion: Int = 1) {
        precondition(!identifier.isEmpty, "capability identifier must not be empty")
        precondition(contractVersion > 0, "contract version must be positive")
        self.identifier = identifier
        self.stability = stability
        self.contractVersion = contractVersion
    }
}

/// Versioned compatibility contract for the public NumericCore ecosystem.
///
/// Capability identifiers and the ordering of ``capabilities`` are shared with
/// Rust-NumericCore. Consumers should branch on identifiers rather than package
/// version strings when selecting optional solver families.
public enum NumericCoreAPI {
    /// Schema of the capability manifest itself.
    public static let manifestSchemaVersion = 1

    /// API compatibility epoch being prepared for the 1.0 release.
    public static let compatibilityEpoch = 1

    /// Public capability catalog, in deterministic identifier order.
    public static let capabilities: [NumericCoreCapability] = [
        .init(identifier: "ampl-modeling", stability: .provisional),
        .init(identifier: "circuit-analysis", stability: .provisional),
        .init(identifier: "dae-integration", stability: .provisional),
        .init(identifier: "dense-linear-algebra", stability: .stable),
        .init(identifier: "engineering-models", stability: .provisional),
        .init(identifier: "fem", stability: .provisional),
        .init(identifier: "global-minlp", stability: .experimental),
        .init(identifier: "iterative-linear-solvers", stability: .stable),
        .init(identifier: "lp-qp-milp", stability: .stable),
        .init(identifier: "multiphysics-design", stability: .experimental),
        .init(identifier: "nonlinear-equations", stability: .provisional),
        .init(identifier: "nonlinear-optimization", stability: .stable),
        .init(identifier: "numerical-validation", stability: .stable),
        .init(identifier: "sparse-linear-algebra", stability: .stable),
    ]

    public static func capability(_ identifier: String) -> NumericCoreCapability? {
        capabilities.first { $0.identifier == identifier }
    }

    public static func supports(_ identifier: String,
                                minimumStability: NumericCoreAPIStability? = nil) -> Bool {
        guard let capability = capability(identifier) else { return false }
        guard let minimumStability else { return true }
        return rank(capability.stability) >= rank(minimumStability)
    }

    private static func rank(_ stability: NumericCoreAPIStability) -> Int {
        switch stability {
        case .experimental: 0
        case .provisional: 1
        case .stable: 2
        }
    }
}
