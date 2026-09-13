#!/usr/bin/env bash
# Syncs the compiled Rust core into this package: builds
# Rust-NumericCore's XCFramework and copies both the framework and the
# UniFFI-generated Swift bindings into place here.
#
# Usage: run from this repo's root, with Rust-NumericCore checked out
# as a sibling directory:
#
#   ~/dev/Swift-NumericCore/   <- you are here
#   ~/dev/Rust-NumericCore/
#
# Override the sibling path with RUST_NUMERICCORE_DIR if your layout
# differs.

set -euo pipefail

RUST_REPO="${RUST_NUMERICCORE_DIR:-../Rust-NumericCore}"

if [ ! -d "${RUST_REPO}" ]; then
    echo "error: Rust-NumericCore not found at ${RUST_REPO}" >&2
    echo "       set RUST_NUMERICCORE_DIR or check it out as a sibling directory" >&2
    exit 1
fi

echo "==> Building XCFramework in ${RUST_REPO}"
(cd "${RUST_REPO}" && ./scripts/build-xcframework.sh)

XCFRAMEWORK_SRC="${RUST_REPO}/target/xcframework/NumericCoreFFI.xcframework"
BINDINGS_SRC="${RUST_REPO}/target/xcframework/bindings"

if [ ! -d "${XCFRAMEWORK_SRC}" ]; then
    echo "error: expected XCFramework not found at ${XCFRAMEWORK_SRC}" >&2
    exit 1
fi

# Guard against UniFFI 0.27's broken Swift for single-field tuple-variant
# errors: it emits `: try ...` (missing argument label) and `write(, into:)`,
# which fail with "expected argument label before colon" / "unexpected ','".
# nc-ffi must declare FfiError::DimensionMismatch as a struct variant
# (`{ message: String }`), never `DimensionMismatch(String)` — see the NOTE
# on the enum in nc-ffi/src/lib.rs. Check BEFORE copying so a broken
# regeneration can never clobber the working tree.
if grep -rn --include='*.swift' -e '^[[:space:]]*: try FfiConverter' -e 'write(, into:' "${BINDINGS_SRC}" 2>/dev/null; then
    echo "error: generated bindings contain broken UniFFI tuple-variant codegen" >&2
    echo "       fix nc-ffi/src/lib.rs (struct variant, see NOTE on FfiError) and rebuild" >&2
    exit 1
fi

echo "==> Copying XCFramework into Frameworks/"
rm -rf Frameworks/NumericCoreFFI.xcframework
cp -R "${XCFRAMEWORK_SRC}" Frameworks/

# Guard against the classic UniFFI + SwiftPM failure mode: Clang only
# auto-loads a modulemap named exactly `module.modulemap` from a header
# search path. If a slice is missing it, `canImport(nc_ffiFFI)` silently
# evaluates false, the generated bindings lose RustBuffer/RustCallStatus,
# and the link fails with undefined symbols for every uniffi_/ffi_
# entry point. build-xcframework.sh is responsible for creating it —
# fail here rather than shipping a broken framework.
for slice in Frameworks/NumericCoreFFI.xcframework/*/; do
    if [ -d "${slice}/Headers" ] && [ ! -f "${slice}/Headers/module.modulemap" ]; then
        echo "error: ${slice}/Headers/module.modulemap missing (build-xcframework.sh regression?)" >&2
        exit 1
    fi
    if ls "${slice}/Headers"/*.swift >/dev/null 2>&1; then
        echo "error: stray *.swift inside ${slice}/Headers/ (headers dir must hold only .h + .modulemap)" >&2
        exit 1
    fi
done

echo "==> Copying generated Swift bindings into Sources/NCBindings/Generated/"
mkdir -p Sources/NCBindings/Generated
find Sources/NCBindings/Generated -name "*.swift" -delete
cp "${BINDINGS_SRC}"/*.swift Sources/NCBindings/Generated/

echo "==> Done. Run 'swift build' to verify, then check both directories"
echo "    into git (Frameworks/ holds a binary; see Frameworks/README.md"
echo "    and docs/decisions/0009-local-binary-target-for-ffi.md for why)."
