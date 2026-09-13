# Sources/NCBindings/Generated/

UniFFI-generated Swift bindings for `nc-ffi`, produced by
`Rust-NumericCore`'s `uniffi-bindgen` and copied here by
`scripts/update-ffi.sh` (or `Rust-NumericCore/scripts/build-xcframework.sh`
directly, then copied by hand).

**Checked into git as source** — unlike `Frameworks/NumericCoreFFI.xcframework`
(a binary), these `.swift` files are ordinary source and belong in
version control like any other generated-but-committed code (comparable
to a generated protobuf/gRPC Swift file).

Do not hand-edit files here — they're regenerated wholesale by
`scripts/update-ffi.sh` whenever `nc-ffi`'s UniFFI interface changes.
If you need different behavior at the Swift call site, add it in
`FFIBridge.swift` (a sibling, hand-written file, not regenerated)
instead.

## If this directory is empty

You haven't run `scripts/update-ffi.sh` yet (or copied the bindings in
by hand from a `Rust-NumericCore` build). `FFIBridge.swift` will not
compile without a generated file here providing `matmulF64`, `dotF64`,
`axpyF64`, `norm2F64`, `spmvF64`, `FfiMatrixF64`, `FfiCsrMatrixF64`, and
`FfiError` — see that file's header comment for the exact expected
shape and what to adjust if the real generated API differs.
