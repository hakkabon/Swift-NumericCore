# 0009 — Local-path binary target for `NumericCoreFFI`, not a remote release yet

## Status
Accepted (revisit once `Rust-NumericCore` has a release cadence).

## Context
`Package.swift`'s `NumericCoreFFI` binary target can point at either a
local path (the `.xcframework` checked into this repo) or a remote
`url:`/`checksum:` pair (an asset on a `Rust-NumericCore` GitHub
release, per ADR 0008's original sketch and
`Rust-NumericCore/.github/workflows/release.yml`).

At the point this was wired up, `Rust-NumericCore` had a working
`scripts/build-xcframework.sh` (confirmed producing real output) but no
tagged release yet. `Swift-DataLens` needs `Swift-NumericCore` to be
addable as a normal SPM dependency and *work*, now.

## Decision
`Package.swift` uses a **local path** binary target:
```swift
.binaryTarget(name: "NumericCoreFFI", path: "Frameworks/NumericCoreFFI.xcframework")
```
The `.xcframework` itself, and the UniFFI-generated Swift bindings
(`Sources/NCBindings/Generated/*.swift`), are **checked into git** —
not gitignored, not fetched at build time. `scripts/update-ffi.sh`
regenerates both from a sibling `Rust-NumericCore` checkout.

## Consequences
- Any consumer (`Swift-DataLens` included) that adds this package via
  `.package(url: "https://github.com/hakkabon/Swift-NumericCore", ...)`
  gets a working FFI layer immediately — no separate release/download
  coordination, no version-skew risk between `Package.swift`'s declared
  dependency and an actual uploaded asset.
- The repo now carries compiled binary content in git history — this
  will bloat clone size over time, especially across multiple
  XCFramework updates (git doesn't diff binaries well). Accepted for
  now; worth revisiting once the binary is updated often enough for
  this to actually hurt.
- Anyone updating the Rust core must remember to run
  `scripts/update-ffi.sh` and commit both directories together — an
  `.xcframework` without matching `Generated/*.swift` (or vice versa)
  is a broken, mismatched pair, not something SPM or the compiler will
  necessarily catch cleanly.
- No `checksum:` verification happens on this path the way a remote
  binary target gets one — a local path is trusted as-is. This is fine
  within one developer's own two repos; it would be worth reconsidering
  if this project ever took external binary contributions.

## What to do before this changes
Once `Rust-NumericCore` has an actual release cadence (tags pushed
regularly enough that pinning a version range makes sense), switch to
the commented-out remote form in `Package.swift`, delete
`Frameworks/NumericCoreFFI.xcframework` from git history if repo size
has become a real problem (via a history-rewrite, not just a future
commit removing the file), and add `Frameworks/` to `.gitignore`.
`Sources/NCBindings/Generated/` can either stay checked in (still
ordinary source) or also move to a fetch-at-build step if the two ever
need to move in lockstep with the binary automatically.

## Alternatives considered
- **Remote `url:`/`checksum:` from the start.** Rejected for now: adds
  a "tag a release, upload an asset, compute a checksum" step to every
  Rust-core change during a period where that core is still actively
  developed alongside its first real Swift consumer — friction with no
  present payoff. Revisit once change frequency drops.
- **Fetch the XCFramework at build time via a build tool
  plugin/pre-build script** instead of checking it in. Rejected: SPM's
  binary-target model doesn't cleanly support "fetch from an arbitrary
  location at resolve time" outside the `url:`/`checksum:` mechanism
  itself; a custom plugin doing this is more moving parts than the
  problem currently justifies.
