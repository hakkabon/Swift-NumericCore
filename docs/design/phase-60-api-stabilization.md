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

## Maintenance interval

- The numerical validation workflow runs weekly and on demand. It collects
  the standard corpus snapshot and the Swift toolchain version. Scheduled
  and manual runs also exercise a fresh SwiftPM consumer against both the
  checkout and the published Swift 1.0.0 version.
- The Swift tests compare schema, compatibility epoch, ordered capability
  identifiers, stability tiers, and contract versions with the linked Rust
  binary. CI also compares its runtime version with `.ffi-version`. Rust
  v0.34.0 may still advertise the two provisional capabilities retired by
  the modeling and circuit split. Newer pins require full catalog parity.
- Verify release assets before shipping. The Swift tag workflow downloads
  the Rust archive and binding from the exact pinned release, checks the
  archive checksum and binding bytes, and builds a consumer against the
  pushed Swift version before notifying consumers.
- Retain published Rust archives and generated bindings for every supported
  Swift tag. Preserve both original files and the archive checksum in release
  backups. If an asset goes missing, restore the exact verified bytes or
  ship a new Rust tag and Swift pin.
- Triage numerical failures using the archived case ID, metric, tolerance,
  solver backend, toolchain, and FFI version. Keep patch releases focused
  on corrections and compatible diagnostics. Review toolchain and CI
  dependency upgrades separately. Promote a provisional capability only
  after documenting its contract and reviewing its conformance evidence.

Run the core suite and clean-checkout consumer locally from the repo root:

```sh
NUMERICCORE_EXPECTED_RUST_TAG="$(cat .ffi-version)" swift test
NUMERICCORE_PACKAGE_PATH="$PWD" swift run --package-path scripts/consumer-smoke
```

To verify files already downloaded from the pinned Rust release, run
`python3 -B scripts/verify_ffi_release.py /path/to/assets`.
