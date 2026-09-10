/// Encapsulates the backend-selection *decision*, kept separate from the
/// backends themselves so it can be tuned, benchmarked, and swapped out
/// (e.g. "force fallback everywhere" for correctness testing) without
/// touching backend code.
///
/// v1 only knows about `RustFallbackBackend` — `AccelerateBackend` and
/// `MPSBackend` are added here once `NumericCoreAccelerate` /
/// `NumericCoreMPS` exist (see those packages' READMEs). The shape below
/// (registered backend list + threshold-based routing) is the intended
/// long-term structure; it's written now so `Dispatcher` has a stable
/// interface to call regardless of how many backends currently exist.
public struct DispatchPolicy {
    /// Below this element count, GPU dispatch overhead isn't worth it.
    /// Placeholder value — must be replaced with a number derived from
    /// `nc-bench` results (see `docs/design/dispatch-thresholds.md`) once
    /// an MPS backend exists to benchmark against.
    public var gpuThreshold: Int

    /// Scalar type names Accelerate accelerates well. Checked via
    /// `NCScalar.dispatchTypeName` rather than a generic constraint,
    /// since capability depends on the *value* of `T`, not just its type
    /// conformance.
    public var accelerateScalarTypeNames: Set<String>

    public init(
        gpuThreshold: Int = 250_000,
        accelerateScalarTypeNames: Set<String> = ["Float", "Double"]
    ) {
        self.gpuThreshold = gpuThreshold
        self.accelerateScalarTypeNames = accelerateScalarTypeNames
    }

    /// Default policy. A test build can substitute
    /// `DispatchPolicy(gpuThreshold: .max, accelerateScalarTypeNames: [])`
    /// to force every operation through `RustFallbackBackend` — useful as
    /// the "known-correct" side of a backend-diffing test.
    public static let `default` = DispatchPolicy()

    /// Choose which backend should run `operation` given problem shape
    /// and scalar type. Never returns a backend whose `capabilities`
    /// don't include `operation`, and never one that fails
    /// `isAvailable()`.
    ///
    /// - Parameters:
    ///   - operation: the single capability being dispatched (callers
    ///     pass one flag, e.g. `.matmul`, not a combined set).
    ///   - elementCount: total elements in the dominant operand — used
    ///     against `gpuThreshold`. Pass `0` for operations where size
    ///     doesn't matter to the decision.
    ///   - scalarTypeName: `T.dispatchTypeName` of the operand type.
    ///   - sparse: whether either operand is sparse — routes around
    ///     Accelerate entirely, since it has no sparse story.
    ///   - candidates: backends to consider, most-preferred first, not
    ///     including the universal fallback (which is appended
    ///     automatically as the last resort).
    public func chooseBackend(
        for operation: BackendCapabilities,
        elementCount: Int,
        scalarTypeName: String,
        sparse: Bool,
        candidates: [any Backend.Type] = []
    ) -> any Backend.Type {
        if sparse {
            return RustFallbackBackend.self
        }

        for candidate in candidates {
            guard candidate.capabilities.contains(operation) else { continue }
            guard candidate.isAvailable() else { continue }

            if candidate.device == .gpu && elementCount < gpuThreshold {
                continue
            }
            if !accelerateScalarTypeNames.contains(scalarTypeName) && candidate.identifier == "accelerate" {
                continue
            }
            return candidate
        }

        return RustFallbackBackend.self
    }
}
