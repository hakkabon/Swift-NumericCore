# Phase 42: nonlinear and transient circuits

The Swift circuit layer mirrors the Rust numerical model for dependent sources,
nonlinear devices, and convergence support. `CircuitDevice` now includes VCCS
and VCVS elements and a three-terminal level-1 NMOS. The MOS stamp evaluates
cutoff, triode, and saturation regions with optional channel-length modulation
and supplies analytic `gm` and `gds` entries to the sparse Newton Jacobian.

`dcOperatingPointContinuation` implements source stepping and `gmin` stepping.
Independent source amplitudes progress from zero to their requested values while
temporary node-to-ground conductance is removed cubically. Each solution seeds
the next stage; the returned residual diagnostics are recomputed on the original
circuit, and `continuationSteps` records the completed stages.

`transientBreakpoints` returns ordered, deduplicated pulse corners in forward or
reverse time. This allows higher-level transient orchestration to align DAE
segments with source discontinuities. The existing transient method continues
to solve the full nonlinear residual and analytic Jacobian at every implicit
step.

This remains a compact educational/engineering model rather than full SPICE
compatibility. Body effect, stored MOS charge, body diodes, temperature models,
PN-junction limiting, automatic segmented restart, AC/noise analysis, and modern
compact transistor models are explicitly deferred.
