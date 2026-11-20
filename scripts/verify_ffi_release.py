#!/usr/bin/env python3
"""Verify that a Rust release's archive and bindings match the Swift checkout."""

import hashlib
import re
import sys
from pathlib import Path

from set_ffi_binary_target import BLOCK_PATTERN, new_block


ROOT = Path(__file__).resolve().parents[1]


def verify(assets: Path) -> str:
    tag = (ROOT / ".ffi-version").read_text().strip()
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag):
        raise ValueError(f"invalid Rust release tag in .ffi-version: {tag!r}")

    manifest = (ROOT / "Package.swift").read_text()
    blocks = BLOCK_PATTERN.findall(manifest)
    if len(blocks) != 1:
        raise ValueError("expected exactly one NumericCoreFFI binary target")

    digest = hashlib.sha256()
    with (assets / "NumericCoreFFI.xcframework.zip").open("rb") as archive:
        for chunk in iter(lambda: archive.read(1024 * 1024), b""):
            digest.update(chunk)
    if blocks[0] != new_block(tag, digest.hexdigest()):
        raise ValueError(f"Package.swift URL or archive checksum disagrees with {tag}")

    bindings = ROOT / "Sources/NCBindings/Generated/nc_ffi.swift"
    if bindings.read_bytes() != (assets / "nc_ffi.swift").read_bytes():
        raise ValueError(f"checked-in UniFFI bindings disagree with {tag}")

    return tag


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: verify_ffi_release.py <downloaded-assets-directory>")
    try:
        print(f"Verified Rust FFI assets for {verify(Path(sys.argv[1]))}")
    except (OSError, ValueError) as error:
        sys.exit(f"FFI verification failed: {error}")
