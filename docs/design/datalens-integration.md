# Integrating with Swift-DataLens's `LinAlg`/`Regression` seam

`Swift-DataLens` calls two internal functions from `Loess.swift`, in
three places, with signatures that must stay exactly as-is:

```swift
LinAlg.leastSquares(design: [[Double]], response: [Double]) -> [Double]?  // nil if rank-deficient
Regression.solve(_ A: [[Double]], _ b: [Double]) -> [Double]?              // nil if pivot ≤ 1e-12
```

`NumericCoreAccelerate.AccelerateBackend.leastSquares(design:response:)`
and `.solve(_:_:)` (see `QRSolve.swift`) implement the same contract —
`nil` on rank deficiency / a near-zero pivot — but operate on
`Matrix<Double>`/`Vector<Double>`, not nested arrays. `Matrix`'s
`init(rows: [[Double]])` and `.rowMajorArray` (see `Matrix.swift`) exist
specifically to make the boundary conversion trivial.

## Suggested `LinAlg.swift` body

```swift
import NumericCore
import NumericCoreAccelerate

enum LinAlg {
    static func leastSquares(design: [[Double]], response: [Double]) -> [Double]? {
        guard let designMatrix = try? Matrix<Double>(rows: design) else { return nil }
        let responseVector = Vector<Double>(response)
        guard let coefficients = try? AccelerateBackend.leastSquares(
            design: designMatrix, response: responseVector
        ) else {
            return nil
        }
        return coefficients?.storage
    }
}
```

## Suggested `Regression.swift` body

```swift
import NumericCore
import NumericCoreAccelerate

enum Regression {
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        guard let matrix = try? Matrix<Double>(rows: a) else { return nil }
        let rhs = Vector<Double>(b)
        guard let solution = try? AccelerateBackend.solve(matrix, rhs) else {
            return nil
        }
        return solution?.storage
    }
}
```

Note the double-optional collapsing (`try?` around a function that
itself returns `T?`): `try? f()` where `f() throws -> T?` produces
`T??`, which needs `?? nil`-flattening or (as above) an explicit
`guard let ... else { return nil }` on the outer optional before
returning the inner one — a `try?`-into-`?`-returning-function is a
common small gotcha here, called out explicitly since both replacement
bodies hit it.

## Why the pivot/rank tolerance defaults match

`AccelerateBackend.solve`'s `pivotTolerance` and `.leastSquares`'s
`rankTolerance` both default to `1e-12` — matching the `≤ 1e-12`
threshold already documented in `Regression.solve`'s existing contract,
so the drop-in replacement doesn't silently change LOESS's numerical
behavior at the boundary. If `Swift-DataLens`'s existing implementation
used a different effective tolerance in practice, compare behavior on
the existing 10-test suite before assuming `1e-12` is exactly
equivalent — the rank check here is on the QR factor `R`'s diagonal
magnitude specifically, which is not numerically identical to whatever
pivot-tracking the previous Gaussian-elimination-based implementation
did, even at the same nominal threshold.

## What this does *not* yet cover

- **SPD-specific solving / eigensolve** — explicitly out of scope per
  the original action items ("can wait for local likelihood"). Nothing
  here blocks adding a `solveSPD` (via `dpotrf_`/`dpotrs`, Cholesky)
  later as a separate, faster path for the specific case where `A` is
  known symmetric positive-definite.
- **Verification**: the existing `QRSolveTests.swift` in this repo
  checks `AccelerateBackend`'s behavior in isolation. It does **not**
  run `Swift-DataLens`'s existing 10-test suite — that verification
  step (per the original action items: "the existing 10 tests pass
  unchanged, plus rank-deficient → nil still holds") has to happen in
  `Swift-DataLens` itself, after wiring the two bodies above, on a real
  Mac toolchain.
