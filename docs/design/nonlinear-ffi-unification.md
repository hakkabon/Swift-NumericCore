# Nonlinear FFI unification

Phase 12 makes the Phase 9 nonlinear graph the executable Swift/Rust boundary.
`NonlinearModelSolver` accepts the existing `NonlinearModel` and returns the
existing Swift result contracts while selecting either `.swift` or `.rust`.

The Rust path transports flat graph nodes, bounds, solver options, robust-loss
configuration, weights, and nonlinear constraints through `NCBindings`.
Objective and derivative evaluation then remain entirely inside Rust for the
duration of a solve; per-iteration Swift callbacks are deliberately excluded.
Closure-based APIs therefore remain Swift-only.

The unified surface covers bounded L-BFGS, bounded and robust nonlinear least
squares, and augmented-Lagrangian constrained optimization. Termination states,
diagnostics, multipliers, iteration counts, and validation failures are mapped
without reducing either implementation's result contract.

The generated Swift binding and `NumericCoreFFI` framework are one versioned
artifact. Any change to the Rust records or exports must regenerate both and
update the binary-target URL and checksum together.
