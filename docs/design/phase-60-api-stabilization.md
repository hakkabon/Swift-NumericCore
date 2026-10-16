# Phase 60 — API stabilization and 1.0 preparation

Phase 60 introduces an explicit compatibility boundary without prematurely
freezing every research-oriented solver. `NumericCoreAPI` is the shared,
machine-readable contract for capability discovery. Its identifiers, stability
vocabulary, schema version, and ordering match Rust-NumericCore.

## Stability policy

- **Stable** APIs are intended to remain source compatible throughout 1.x.
  Incompatible changes require a major release. Additive options must have
  defaults, result fields retain their meaning, and termination states are not
  silently reinterpreted.
- **Provisional** APIs are supported and tested but may receive focused naming
  or representation changes before 1.0. Changes require release notes and a
  migration path whenever practical.
- **Experimental** APIs may evolve as algorithms mature. They carry no 1.x
  source-compatibility promise until promoted.

Stability concerns the API contract, not numerical correctness. Every tier is
subject to validation, deterministic reporting, finite-input checks, and
explicit termination behavior.

## 1.0 release gates

1. Swift and Rust capability manifests remain identical.
2. Stable APIs have public documentation and conformance tests.
3. Swift, Rust, and UniFFI version pins are released atomically and CI verifies
   generated bindings against their framework.
4. Stable solvers use independent certificates or residual diagnostics where
   applicable.
5. The standard validation corpus passes on all supported platforms.
6. Provisional and experimental modules are clearly identified in release
   notes so 1.0 does not imply that their surfaces are frozen.

The compatibility epoch is `1`; it is deliberately independent of package
versions and can therefore be tested before the first stable release.
