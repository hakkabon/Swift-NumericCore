# Phase 36: derivative-free optimization

Phase 36 turns the Phase 35 Powell direction-set implementation into a broader
value-only optimization capability. Swift and Rust now provide matching native
implementations of two additional methods:

- bound-aware Nelder-Mead, including reflection, expansion, contraction, and
  shrink steps;
- deterministic coordinate pattern search for nonsmooth box-constrained
  objectives.

Both methods project their initial point and every trial point into the supplied
box. They reject malformed bounds and non-finite objective values, impose hard
evaluation as well as iteration limits, support observer cancellation, and
return method-specific convergence diagnostics. Nelder-Mead reports final
simplex diameter and objective spread. Pattern search reports its final poll
step and successful-poll count.

The methods complement rather than replace the existing solvers. Powell
direction-set remains useful for smooth unconstrained problems, Nelder-Mead is
a flexible small-dimensional local method, and coordinate pattern search is the
most predictable choice for nonsmooth bounded objectives. None provides a
global-optimality certificate.

This phase deliberately stays on the native callback APIs. Arbitrary Swift
closures cannot cross UniFFI, and adding generated bindings would falsely imply
that callbacks are portable. A later model-level bridge can run the shared
value-only nonlinear graph wholly inside Rust without changing these APIs.
