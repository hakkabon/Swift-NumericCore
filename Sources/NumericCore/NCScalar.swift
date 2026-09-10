/// Element type usable in `Matrix<T>` / `Vector<T>`.
///
/// v1 deliberately only conforms `Float` and `Double` (see extensions
/// below) — Accelerate is optimized for those two, and generalizing to
/// other numeric types before the API has stabilized under real usage is
/// the kind of premature generality this project explicitly wants to
/// avoid. Adding e.g. `Complex<Double>` later means adding a conformance
/// here plus backend support — it does not mean redesigning `Matrix`.
public protocol NCScalar: Numeric {
    /// The name Accelerate/dispatch logic switches on. Using a stored
    /// string (rather than `String(describing: Self.self)` at every call
    /// site) keeps `DispatchPolicy` allocation-free on the hot path.
    static var dispatchTypeName: String { get }

    /// Required so `RustFallbackBackend.norm` can compute an L2 norm
    /// without runtime type-casting. Both current conformers (`Float`,
    /// `Double`) already have this natively.
    func squareRoot() -> Self
}

extension Float: NCScalar {
    public static var dispatchTypeName: String { "Float" }
}

extension Double: NCScalar {
    public static var dispatchTypeName: String { "Double" }
}
