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

echo "==> Copying XCFramework into Frameworks/"
rm -rf Frameworks/NumericCoreFFI.xcframework
cp -R "${XCFRAMEWORK_SRC}" Frameworks/

echo "==> Copying generated Swift bindings into Sources/NCBindings/Generated/"
mkdir -p Sources/NCBindings/Generated
find Sources/NCBindings/Generated -name "*.swift" -delete
cp "${BINDINGS_SRC}"/*.swift Sources/NCBindings/Generated/

echo "==> Done. Run 'swift build' to verify, then check both directories"
echo "    into git (Frameworks/ holds a binary; see Frameworks/README.md"
echo "    and docs/decisions/0009-local-binary-target-for-ffi.md for why)."
