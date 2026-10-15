# Phase 57 — Engineering sensitivities and adjoints

Phase 57 turns the exact parameter derivatives already assembled by the shared
engineering representation into solution and response sensitivities. At an
operating point the implementation forms the sparse effective tangent
`A = F_y + alpha F_ydot`. Steady analysis uses `alpha = 0`; an implicit DAE
step can provide its local relation `d(ydot)/dp = alpha dy/dp`.

Forward mode solves `A dy/dp = -F_p` for every model parameter. For scalar
responses, adjoint mode solves `A^T lambda = dg/dy` and evaluates the total
gradient `dg/dp = partial(g)/partial(p) - F_p^T lambda`. Both paths reuse one
sparse factorization per tangent and expose residual norms. The result also
contracts each response through the forward sensitivities and reports the
forward-adjoint mismatch as an independent correctness certificate.

The API is domain neutral: circuit operating points, static mechanics, thermal
models, and implicit engineering time steps can share it once represented by
`EngineeringModel`. It deliberately analyzes a supplied operating point and
does not differentiate event times, adaptive time-step decisions, eigenvalue
clusters, contact active sets, or remeshing decisions. Those require dedicated
discrete trajectory and nonsmooth sensitivity policies in later phases.
