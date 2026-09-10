# 0007 — `Dispatcher`'s global mutable state is not thread-safe (v1 accepted gap)

## Status
Accepted (revisit before any concurrent use).

## Context
`Dispatcher.policy` and `Dispatcher.registeredBackends` are mutable
static properties, read on every dispatched operation and written
whenever a caller changes the active policy or registers a backend
(e.g. a test forcing `RustFallbackBackend` everywhere, or an app
enabling `AccelerateBackend` at startup). Swift does not synchronize
access to these for free.

## Decision
v1 accepts this as-is: `Dispatcher` is designed for a single-threaded
numeric pipeline (parse a model, build matrices, solve, read results —
sequentially), which is the initial target usage. No locks, actors, or
`Sendable` conformance are added yet.

## Consequences
- Calling `Matrix`/`Vector` operations concurrently from multiple
  threads while also mutating `Dispatcher.policy` or
  `.registeredBackends` from another thread is a data race. Concurrent
  *reads* (multiple threads calling `matmul` without anyone mutating
  policy/backends) are likely fine in practice on current Swift runtimes
  but are not a guarantee this ADR makes.
- `Dispatcher` is not `Sendable`, and no attempt is made to make it so
  in v1.

## What to do before this changes
If/when concurrent usage becomes real (e.g. solving multiple independent
`Problem`s in parallel, or a UI thread reading results while a
background thread computes), do not patch this incrementally. Redesign
`Dispatcher` as an `actor` or make `DispatchPolicy`/backend registration
immutable-after-configuration (e.g. configured once at app startup,
then treated as read-only for the rest of the process lifetime — which
may be sufficient without actor overhead). Decide explicitly which of
these two shapes fits the actual concurrent use case before
implementing either.

## Alternatives considered
- **Make `Dispatcher` an actor now.** Rejected for v1: adds `await` to
  every single `Matrix`/`Vector` operation call site, which is a real
  ergonomics cost, for a concurrency need that doesn't exist yet given
  the single-threaded pipeline this is currently built for.
