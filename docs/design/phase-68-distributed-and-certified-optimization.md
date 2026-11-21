# Phase 68 — Distributed and certified optimization

`DistributedBendersCoordinator` accepts the existing `BendersProblem` for
continuous two-stage LPs. The recourse objective must have a finite lower
bound from its local variable bounds.

Call `pendingJobs()` and send each job's `json` to a worker. Swift can run
the same worker through `executeJob(_:)`. Other hosts can run the Rust
`nc-benders-worker` executable with one JSON job per input line. Submit
replies through `submit(_:)` in any arrival order. `progress()` reports
the current status, verified bounds, and incumbent.

Use `exportCheckpoint()` for restart and pass it back with the original
model. Accepted replies from the open round are retained and checked on
resume. The coordinator advances once every scenario has provided valid
evidence for that round. Identical retries are idempotent. A worker that
cannot supply evidence leaves its job pending.

Use `exportProof()` to record completed evidence and
`verify(problem:proof:options:)` to recheck it against the original model.
Verification rebuilds the cuts and evaluates the LP certificates without
running the optimizer. Claims use the verifier's numerical tolerances.

The provisional `distributed-benders` capability activates after release
synchronization installs the matching Rust binary and UniFFI bindings.
`DistributedBendersCoordinator.isAvailable` exposes that availability.
