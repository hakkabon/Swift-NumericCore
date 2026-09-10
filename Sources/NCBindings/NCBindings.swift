/// Raw, unsafe wrapper around the Rust core, generated/hand-written
/// against `nc-ffi`'s UniFFI surface.
///
/// **This target is not public API.** Only `NumericCore` (and, for
/// sparse types, `NumericCoreSparse`) should import it. Application code
/// should never import `NCBindings` directly — the whole point of the
/// `Backend` abstraction is that callers work with `Matrix`/`Vector` and
/// never see a raw pointer or an FFI handle.
///
/// Currently empty: `nc-ffi` has no real UniFFI exports yet (see that
/// crate's module docs). Once it does, this file becomes the hand-written
/// glue around the UniFFI-generated Swift bindings — e.g. wrapping the
/// generated `NcBuffer` handle type in something `NumericCore.Matrix`'s
/// initializers can consume without every call site touching UniFFI
/// directly.
public enum NCBindingsPlaceholder {
    /// Smoke test only — confirms the target builds and links.
    /// Delete once real bindings exist.
    public static func isScaffold() -> Bool { true }
}
