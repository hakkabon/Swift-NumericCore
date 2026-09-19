#!/usr/bin/env python3
"""Rewrites Package.swift's `NumericCoreFFI` binaryTarget to point at a
specific Rust-NumericCore release (remote `url:` + `checksum:`).

Idempotent and form-agnostic: works whether the current block is the
original local `path:` form (ADR 0009) or an earlier remote pin from a
previous run of this script — both get replaced wholesale.

Used by `.github/workflows/update-ffi.yml`; see
`docs/decisions/0010-automated-ffi-release-pipeline.md` for why this
exists instead of hand-editing `Package.swift` after every
Rust-NumericCore release. Not expected to be run by hand, but safe to:

    python3 scripts/set_ffi_binary_target.py v0.1.0 <checksum>
"""
import re
import sys

BLOCK_PATTERN = re.compile(
    r'        \.binaryTarget\(\n            name: "NumericCoreFFI",\n.*?\n        \),',
    re.DOTALL,
)


def new_block(tag: str, checksum: str) -> str:
    url = f"https://github.com/hakkabon/Rust-NumericCore/releases/download/{tag}/NumericCoreFFI.xcframework.zip"
    return (
        '        .binaryTarget(\n'
        '            name: "NumericCoreFFI",\n'
        f'            url: "{url}",\n'
        f'            checksum: "{checksum}"\n'
        '        ),'
    )


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: set_ffi_binary_target.py <tag> <checksum>", file=sys.stderr)
        return 1
    tag, checksum = sys.argv[1], sys.argv[2]

    path = "Package.swift"
    with open(path) as f:
        content = f.read()

    if not BLOCK_PATTERN.search(content):
        print(f"error: could not find the NumericCoreFFI binaryTarget block in {path}", file=sys.stderr)
        return 1

    content = BLOCK_PATTERN.sub(new_block(tag, checksum), content, count=1)
    with open(path, "w") as f:
        f.write(content)

    print(f"Package.swift now pins NumericCoreFFI to {tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
