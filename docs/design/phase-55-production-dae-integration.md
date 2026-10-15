# Phase 55 — Production DAE integration

Phase 55 strengthens the residual-form index-1 DAE path around the failure
modes that matter in engineering workflows: inconsistent starts, events, and
known discontinuities. It extends the existing adaptive implicit integrator
instead of creating a circuit-specific time solver.

`TimeIntegrator.consistentDAEInitialConditions` performs a Newton correction of
`F(t, y, yDot) = 0`. For every component the caller chooses whether its state or
derivative is free. The resulting square Newton matrix selects the matching
column from `F_y` or `F_yDot`, which supports singular mass matrices while
keeping the user's chosen physical initial data fixed. The result reports the
corrected pair, residual norm, work, and correction partition. Invalid shapes,
singular selections, non-finite iterates, and nonconvergence fail explicitly.

DAE integration now shares the ODE event contract: multiple event functions,
rising/falling/any direction filters, structured event records, terminal
termination, and observer cancellation. Roots are located over accepted-step
Hermite interpolants, including a derivative at a terminal root.

Hard stop times prevent implicit steps from crossing known discontinuities.
`CircuitModel.transient` automatically supplies its waveform breakpoints, so
SPICE `PULSE` edges compiled in Phase 54 are honored without extra caller code.
Stop times are validated, ordered for forward or reverse integration,
deduplicated, and retained as accepted output points.

The standard validation corpus now corrects a singular-mass index-1 initial
condition, observes a hard stop, and locates a terminal event against an
analytic reference. Swift and Rust expose matching behavior.

The underlying time step remains adaptive, Newton-corrected backward Euler
with step doubling. Variable-order BDF, sparse Newton factor reuse, algebraic
event projection, and index reduction remain future depth rather than being
implied by the production orchestration added here.
