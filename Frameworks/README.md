# Frameworks/

This directory holds `NumericCoreFFI.xcframework` — the compiled
Rust core (`nc-ffi`), built by
[`Rust-NumericCore`](https://github.com/hakkabon/Rust-NumericCore)'s
`scripts/build-xcframework.sh`.

**This binary is checked into git**, deliberately — see
`docs/decisions/0009-local-binary-target-for-ffi.md`. `Package.swift`'s
`NumericCoreFFI` binary target currently points here via a local
`path:`, not a remote `url:`/`checksum:`, which means downstream
consumers (e.g. `Swift-DataLens`) get a working FFI layer the moment
they add this package as a dependency — no separate release/download
step, no version skew between what's declared in `Package.swift` and
what's actually present.

## Keeping this up to date

Run `scripts/update-ffi.sh` from the repo root. It expects
`Rust-NumericCore` checked out as a sibling directory
(`../Rust-NumericCore` relative to this repo), runs that repo's
`scripts/build-xcframework.sh`, and copies both the resulting
`.xcframework` here and the generated Swift bindings into
`Sources/NCBindings/Generated/`.

## Migrating to a remote binary target later

Once `Rust-NumericCore` starts tagging releases and you'd rather not
carry compiled binaries in `Swift-NumericCore`'s git history, switch
`Package.swift`'s `NumericCoreFFI` target to the commented-out
`url:`/`checksum:` form there, remove this directory's contents, and
add it to `.gitignore`. See ADR 0009 for the tradeoffs either way.
