# Frameworks/

**Transitional — this directory is being phased out.** As of ADR 0010,
`Package.swift`'s `NumericCoreFFI` binary target is moving to a remote
`url:`/`checksum:` pin instead of vendoring the compiled framework
here. The first successful run of `.github/workflows/update-ffi.yml`
after a Rust-NumericCore release exists will remove this directory
automatically as part of its update PR — nothing to do by hand beyond
merging that PR. See ADR 0010 for the full pipeline and ADR 0009 for
why this directory existed in the first place.

Everything below describes the outgoing local-vendoring approach, kept
for reference until the directory is actually removed.

---

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

The last-vendored Rust tag is recorded in `FFI_VERSION` (`unreleased`
until the first tagged vendor). Do not vendor a framework without its
same-release bindings — update-ffi.sh always copies both together.

### Automatic updates on Rust version tags

`.github/workflows/update-ffi.yml` does the same vendoring
automatically: Rust-NumericCore's `release.yml` notifies this repo on
every `v*.*.*` tag (plus a weekly poll as fallback), and the workflow
opens a PR refreshing this directory, `Sources/NCBindings/Generated/`,
and `FFI_VERSION`, after passing `swift build` + `swift test`.
Prefer letting the bot open the PR over hand-copying release assets —
the workflow also enforces the `Headers/module.modulemap` guard below.

### Why `Headers/module.modulemap` must exist in every slice

UniFFI generates `<crate>FFI.modulemap` (`nc_ffiFFI.modulemap`), but
Clang only auto-loads a modulemap named exactly `module.modulemap`
from a header search path. Without that copy, `canImport(nc_ffiFFI)`
in the generated bindings silently evaluates false, `RustBuffer` /
`RustCallStatus` / `ForeignBytes` vanish, and the link fails with
undefined symbols for every `uniffi_*` / `ffi_*` entry point.
`build-xcframework.sh` creates the copy; `update-ffi.sh` and the
update workflow refuse to proceed without it. Never delete it, and
never place `*.swift` inside `Headers/` (headers hold only `.h` +
`.modulemap`; Swift bindings live in `Sources/NCBindings/Generated/`).

## Migrating to a remote binary target later

Once `Rust-NumericCore` starts tagging releases and you'd rather not
carry compiled binaries in `Swift-NumericCore`'s git history, switch
`Package.swift`'s `NumericCoreFFI` target to the commented-out
`url:`/`checksum:` form there, remove this directory's contents, and
add it to `.gitignore`. See ADR 0009 for the tradeoffs either way.
