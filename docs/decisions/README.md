# Decision records

Full ADR set for the `NumericCore` project overall (both repos). This
repo (`Swift-NumericCore`) keeps the complete set since it's the more
likely entry point for a new reader; `Rust-NumericCore` keeps the subset
that bears directly on the Rust workspace's own scope (0002–0005, 0008,
0010).

Read in order — later ones assume earlier ones. Start with 0008 if you
just want to understand why there are two repositories at all, or 0010
for how the FFI binary is packaged and kept in sync today (0009 records
the earlier local-vendoring approach 0010 superseded).
