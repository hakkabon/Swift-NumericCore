/// Swift-friendly adapter over the UniFFI-generated bindings in
/// `Generated/` — the only part of `NCBindings` that talks in terms of
/// plain Swift types (`[Double]`, `Int`), rather than the generated
/// `Ffi*` types directly.
///
/// **This target does not import `NumericCore`.** `NumericCore` depends
/// on `NCBindings` (see `Package.swift`), not the other way around —
/// making `NCBindings` depend back on `NumericCore` would be a circular
/// dependency. That's why this file's public API works with raw arrays
/// and a small `FFIMatrix` struct rather than `Matrix<Double>`/
/// `Vector<Double>` directly; `RustFallbackBackend` (in `NumericCore`)
/// does the conversion at its call sites.
///
/// ## The biggest source of risk in this file
/// This was written **without a Swift compiler or the actual generated
/// bindings file available** — `Generated/` was empty at the time of
/// writing (see that directory's README). The exact names below
/// (`matmulF64`, `FfiMatrixF64`, `FfiError.DimensionMismatch`, etc.) are
/// a best-effort prediction of UniFFI 0.27's Swift codegen conventions
/// (Rust `snake_case` functions → Swift `camelCase`; Rust `PascalCase`
/// types *and enum variants* stay `PascalCase`), applied
/// to the exact function/type names declared in `nc-ffi/src/lib.rs`
/// (`matmul_f64`, `dot_f64`, `axpy_f64`, `norm2_f64`, `spmv_f64`,
/// `FfiMatrixF64`, `FfiCsrMatrixF64`, `FfiError::DimensionMismatch`).
///
/// **Once `Generated/` is populated (via `scripts/update-ffi.sh`),
/// build this target first, in isolation, before anything depending on
/// it.** If the compiler reports an unknown identifier here, open the
/// actual generated file, find the real name, and fix the call site
/// below — the fix is local to this file; nothing about
/// `RustFallbackBackend`'s or `SparseMatrix`'s public API should need
/// to change.
///
/// Note (verified against UniFFI 0.27.3 output): enum cases keep their
/// Rust `PascalCase` (`FfiError.DimensionMismatch`), *not* Swift
/// `camelCase`. `FFIKernels.translate` matches on `.DimensionMismatch` —
/// do not "fix" it to `.dimensionMismatch`; that will not compile.
///
/// `FfiSolveStatus` (added for `solveLPSimplex`/`solveLPInteriorPoint`
/// below) is a plain `uniffi::Enum`, not a `uniffi::Error` — the
/// PascalCase-preservation above is *confirmed* for the error-derive
/// path specifically; whether a plain enum's fieldless cases follow the
/// same rule or get camelCased is an **unconfirmed extension** of that
/// evidence. `FFIKernels.translate(status:)` matches on `.Optimal`
/// (PascalCase) as the primary guess; if the compiler disagrees, this
/// is the one spot to fix, matching the "fix it locally" pattern this
/// whole file follows.
public enum FFIError: Error {
    case dimensionMismatch(String)
    case solverError(String)
    case unknown(String)
}

/// A dense matrix crossing the `NCBindings` boundary — the
/// hand-written-code equivalent of `nc-ffi::FfiMatrixF64`, kept as a
/// separate type (rather than exposing `FfiMatrixF64` directly to
/// `NumericCore`) so a future change to the generated type's exact
/// shape doesn't ripple past this file.
public struct FFIMatrix {
    public let rows: Int
    public let cols: Int
    public let data: [Double]

    public init(rows: Int, cols: Int, data: [Double]) {
        self.rows = rows
        self.cols = cols
        self.data = data
    }
}

/// The `Float` counterpart of `FFIMatrix`, for the `nc-ffi::*_f32`
/// exports.
public struct FFIMatrixFloat {
    public let rows: Int
    public let cols: Int
    public let data: [Float]

    public init(rows: Int, cols: Int, data: [Float]) {
        self.rows = rows
        self.cols = cols
        self.data = data
    }
}

/// Thin wrappers over the generated free functions. Each one:
/// 1. converts Swift `Int`/`FFIMatrix` inputs to the generated types'
///    expected shape (`UInt32`, `FfiMatrixF64`, ...),
/// 2. calls the generated function,
/// 3. converts the result (or a thrown `FfiError`) back.
public enum FFIKernels {
    public static func matmul(_ a: FFIMatrix, _ b: FFIMatrix) throws -> FFIMatrix {
        do {
            let result = try matmulF64(
                a: FfiMatrixF64(rows: UInt32(a.rows), cols: UInt32(a.cols), data: a.data),
                b: FfiMatrixF64(rows: UInt32(b.rows), cols: UInt32(b.cols), data: b.data)
            )
            return FFIMatrix(rows: Int(result.rows), cols: Int(result.cols), data: result.data)
        } catch {
            throw Self.translate(error)
        }
    }

    public static func matmulFloat(_ a: FFIMatrixFloat, _ b: FFIMatrixFloat) throws -> FFIMatrixFloat {
        do {
            let result = try matmulF32(
                a: FfiMatrixF32(rows: UInt32(a.rows), cols: UInt32(a.cols), data: a.data),
                b: FfiMatrixF32(rows: UInt32(b.rows), cols: UInt32(b.cols), data: b.data)
            )
            return FFIMatrixFloat(rows: Int(result.rows), cols: Int(result.cols), data: result.data)
        } catch {
            throw Self.translate(error)
        }
    }

    public static func dot(_ x: [Double], _ y: [Double]) throws -> Double {
        do {
            return try dotF64(x: x, y: y)
        } catch {
            throw Self.translate(error)
        }
    }

    public static func dotFloat(_ x: [Float], _ y: [Float]) throws -> Float {
        do {
            return try dotF32(x: x, y: y)
        } catch {
            throw Self.translate(error)
        }
    }

    /// `result = alpha * x + y`. Matches `nc-ffi::axpy_f64`'s
    /// return-a-new-array shape (see that function's doc comment for
    /// why it isn't `inout`) — `RustFallbackBackend`'s `axpy` wraps this
    /// back into the `inout`-style `Backend` protocol method.
    public static func axpy(alpha: Double, _ x: [Double], _ y: [Double]) throws -> [Double] {
        do {
            return try axpyF64(alpha: alpha, x: x, y: y)
        } catch {
            throw Self.translate(error)
        }
    }

    public static func axpyFloat(alpha: Float, _ x: [Float], _ y: [Float]) throws -> [Float] {
        do {
            return try axpyF32(alpha: alpha, x: x, y: y)
        } catch {
            throw Self.translate(error)
        }
    }

    public static func norm2(_ x: [Double]) -> Double {
        norm2F64(x: x)
    }

    public static func norm2Float(_ x: [Float]) -> Float {
        norm2F32(x: x)
    }

    public static func spmv(
        rows: Int,
        cols: Int,
        rowPointers: [Int],
        columnIndices: [Int],
        values: [Double],
        x: [Double]
    ) throws -> [Double] {
        do {
            let matrix = FfiCsrMatrixF64(
                rows: UInt32(rows),
                cols: UInt32(cols),
                rowPtr: rowPointers.map { UInt32($0) },
                colIndices: columnIndices.map { UInt32($0) },
                values: values
            )
            return try spmvF64(matrix: matrix, x: x)
        } catch {
            throw Self.translate(error)
        }
    }

    public static func spmvFloat(
        rows: Int,
        cols: Int,
        rowPointers: [Int],
        columnIndices: [Int],
        values: [Float],
        x: [Float]
    ) throws -> [Float] {
        do {
            let matrix = FfiCsrMatrixF32(
                rows: UInt32(rows),
                cols: UInt32(cols),
                rowPtr: rowPointers.map { UInt32($0) },
                colIndices: columnIndices.map { UInt32($0) },
                values: values
            )
            return try spmvF32(matrix: matrix, x: x)
        } catch {
            throw Self.translate(error)
        }
    }

    /// Translates the generated `FfiError` into this file's stable
    /// `FFIError`. Isolated in one place so `NumericCore`/
    /// `NumericCoreSparse` never need to know about the generated error
    /// type's exact shape.
    private static func translate(_ error: Error) -> FFIError {
        guard let ffiError = error as? FfiError else {
            return .unknown(String(describing: error))
        }
        switch ffiError {
        case .DimensionMismatch(let message):
            return .dimensionMismatch(message)
        case .SolverError(let message):
            return .solverError(message)
        }
    }
}

// MARK: - LP solving

/// Mirrors `nc-ffi::FfiBound` — `nil` means unbounded in that
/// direction, same convention as `nc_optimize::Bound`.
public struct FFIBound {
    public let lower: Double?
    public let upper: Double?

    public init(lower: Double?, upper: Double?) {
        self.lower = lower
        self.upper = upper
    }
}

/// Mirrors `nc-ffi::FfiProblem`. The constraint matrix is given in raw
/// CSR components (matching `SparseMatrix`'s own internal shape,
/// exposed via its `csrRowPointers`/`csrColumnIndices`/`csrValues`
/// accessors) rather than as an `FFIMatrix`-style dense type — LPs of
/// any real size have sparse constraint matrices, and `NumericCoreAMPL`
/// already builds a `SparseMatrix` in `Presolve.swift`.
public struct FFIProblem {
    public let objective: [Double]
    public let constraintRows: Int
    public let constraintCols: Int
    public let constraintRowPointers: [Int]
    public let constraintColumnIndices: [Int]
    public let constraintValues: [Double]
    public let rowBounds: [FFIBound]
    public let varBounds: [FFIBound]

    public init(
        objective: [Double],
        constraintRows: Int,
        constraintCols: Int,
        constraintRowPointers: [Int],
        constraintColumnIndices: [Int],
        constraintValues: [Double],
        rowBounds: [FFIBound],
        varBounds: [FFIBound]
    ) {
        self.objective = objective
        self.constraintRows = constraintRows
        self.constraintCols = constraintCols
        self.constraintRowPointers = constraintRowPointers
        self.constraintColumnIndices = constraintColumnIndices
        self.constraintValues = constraintValues
        self.rowBounds = rowBounds
        self.varBounds = varBounds
    }
}

/// Mirrors `nc-ffi::FfiSolveStatus`. See the naming caveat on
/// `FFIError`'s doc comment above — this is the one place that
/// depends on the *unconfirmed* extension of the PascalCase-enum-case
/// evidence.
public enum FFISolveStatus {
    case optimal
    case infeasible
    case unbounded
    case iterationLimit
}

/// Mirrors `nc-ffi::FfiSolution`.
public struct FFISolution {
    public let variableValues: [Double]
    public let objectiveValue: Double
    public let status: FFISolveStatus
}

extension FFIKernels {
    /// Solves via `nc-optimize::RevisedSimplexSolver`. See that
    /// solver's Rust-side module docs for when to prefer it over
    /// `solveLPInteriorPoint` (rigorous infeasibility/unboundedness
    /// detection, equality constraints, fixed variables).
    public static func solveLPSimplex(_ problem: FFIProblem) throws -> FFISolution {
        do {
            let result = try solveLpSimplex(problem: makeFfiProblem(problem))
            return makeFFISolution(result)
        } catch {
            throw Self.translate(error)
        }
    }

    /// Solves via `nc-optimize::InteriorPointSolver`. Throws
    /// `FFIError.solverError` (not a crash, not a silently wrong
    /// answer) if `problem` has an equality-constrained row or a fixed
    /// variable — see that solver's Rust-side module docs.
    public static func solveLPInteriorPoint(_ problem: FFIProblem) throws -> FFISolution {
        do {
            let result = try solveLpInteriorPoint(problem: makeFfiProblem(problem))
            return makeFFISolution(result)
        } catch {
            throw Self.translate(error)
        }
    }

    private static func makeFfiProblem(_ problem: FFIProblem) -> FfiProblem {
        FfiProblem(
            objective: problem.objective,
            constraints: FfiCsrMatrixF64(
                rows: UInt32(problem.constraintRows),
                cols: UInt32(problem.constraintCols),
                rowPtr: problem.constraintRowPointers.map { UInt32($0) },
                colIndices: problem.constraintColumnIndices.map { UInt32($0) },
                values: problem.constraintValues
            ),
            rowBounds: problem.rowBounds.map { FfiBound(lower: $0.lower, upper: $0.upper) },
            varBounds: problem.varBounds.map { FfiBound(lower: $0.lower, upper: $0.upper) }
        )
    }

    private static func makeFFISolution(_ result: FfiSolution) -> FFISolution {
        let status: FFISolveStatus
        switch result.status {
        case .Optimal: status = .optimal
        case .Infeasible: status = .infeasible
        case .Unbounded: status = .unbounded
        case .IterationLimit: status = .iterationLimit
        }
        return FFISolution(
            variableValues: result.variableValues,
            objectiveValue: result.objectiveValue,
            status: status
        )
    }
}
