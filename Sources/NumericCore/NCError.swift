/// Errors surfaced by `NumericCore`'s public API.
///
/// Kept separate from `BackendError` (see `Backend.swift`): `NCError` is
/// what callers of `Matrix`/`Vector` see; `BackendError` is what backend
/// implementations throw internally. `Dispatcher` translates between
/// them so a caller never needs to know which backend ran.
public enum NCError: Error, Equatable {
    case dimensionMismatch(String)
    case unsupportedOperation(String)
    case unsupportedScalarType(String)
    case noAvailableBackend(operation: String)
}
