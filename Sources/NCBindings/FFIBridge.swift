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
/// Note (verified against UniFFI 0.27.3 output): `FfiError` (a
/// `uniffi::Error`) keeps its Rust `PascalCase` case names
/// (`FfiError.DimensionMismatch`), *not* Swift `camelCase` —
/// `FFIKernels.translate` matches on `.DimensionMismatch`; do not "fix"
/// it to `.dimensionMismatch`, that will not compile.
///
/// `FfiSolveStatus` (a plain `uniffi::Enum`, not `uniffi::Error`) does
/// *not* follow that same rule — its fieldless cases camelCase as
/// usual (`.optimal`, not `.Optimal`), confirmed once real generated
/// bindings existed. `FfiError`'s PascalCase behavior is specific to
/// the error-derive path, not a general "UniFFI enums stay PascalCase"
/// rule — worth remembering as two separate facts, not one.
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

/// A `Double` CSR matrix crossing the hand-written Swift/Rust boundary.
///
/// This deliberately mirrors the public raw CSR accessors on
/// `NumericCoreSparse.SparseMatrix`, while keeping generated UniFFI record
/// names out of the public Swift-facing adapter API.
public struct FFICSRMatrix: Sendable, Hashable {
    public let rows: Int
    public let cols: Int
    public let rowPointers: [Int]
    public let columnIndices: [Int]
    public let values: [Double]

    public init(
        rows: Int, cols: Int, rowPointers: [Int], columnIndices: [Int], values: [Double]
    ) {
        self.rows = rows
        self.cols = cols
        self.rowPointers = rowPointers
        self.columnIndices = columnIndices
        self.values = values
    }
}

/// Stable Swift representation of a sparse statistical solve performed in
/// Rust. `converged` must be true before `solution` is used as a fitted model.
public struct FFISparseStatisticalSolveResult: Sendable, Hashable {
    public let solution: [Double]
    public let iterations: Int
    public let residualNorm: Double
    public let converged: Bool
    public let weightedResidualSumOfSquares: Double
    public let penaltyContribution: Double
    public let objective: Double

    fileprivate init(_ result: FfiSparseStatisticalSolveResult) {
        solution = result.solution
        iterations = Int(result.iterations)
        residualNorm = result.residualNorm
        converged = result.converged
        weightedResidualSumOfSquares = result.weightedResidualSumOfSquares
        penaltyContribution = result.penaltyContribution
        objective = result.objective
    }
}

public enum FFILinearPreconditioner: Sendable, Hashable {
    case none, jacobi, ilu0, incompleteCholesky

    fileprivate var generated: FfiLinearPreconditioner {
        switch self {
        case .none: return .none
        case .jacobi: return .jacobi
        case .ilu0: return .ilu0
        case .incompleteCholesky: return .incompleteCholesky
        }
    }
}

public struct FFILinearSolveOptions: Sendable, Hashable {
    public let maxIterations: Int
    public let tolerance: Double
    public let initialSolution: [Double]?
    public let preconditioner: FFILinearPreconditioner

    public init(maxIterations: Int, tolerance: Double, initialSolution: [Double]? = nil,
                preconditioner: FFILinearPreconditioner = .jacobi) {
        self.maxIterations = maxIterations; self.tolerance = tolerance
        self.initialSolution = initialSolution; self.preconditioner = preconditioner
    }
}

public enum FFIIterativeTermination: Sendable, Hashable {
    case converged, iterationLimit, breakdown
}

public struct FFILinearSolveResult: Sendable, Hashable {
    public let solution: [Double]
    public let iterations: Int
    public let residualNorm: Double
    public let relativeResidual: Double
    public let termination: FFIIterativeTermination

    fileprivate init(_ result: FfiLinearSolveResult) {
        solution = result.solution; iterations = Int(result.iterations)
        residualNorm = result.residualNorm; relativeResidual = result.relativeResidual
        switch result.termination {
        case .converged: termination = .converged
        case .iterationLimit: termination = .iterationLimit
        case .breakdown: termination = .breakdown
        }
    }
}

public struct FFISparseDirectResult: Sendable, Hashable {
    public let solution: [Double]
    public let residualNorm: Double
    public let relativeResidual: Double
    public let factorNonzeros: Int

    fileprivate init(_ result: FfiSparseDirectResult) {
        solution = result.solution; residualNorm = result.residualNorm
        relativeResidual = result.relativeResidual; factorNonzeros = Int(result.factorNonzeros)
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

    /// Runs the portable CSR CGLS solve for
    /// `min Σ wᵢ(yᵢ - xᵢᵀβ)²`. Zero weights exclude observations.
    ///
    /// This is intentionally a result-returning iterative API: a numerical
    /// iteration limit yields `converged == false`, not a silently accepted
    /// fit. Shape and non-finite input failures are thrown.
    public static func solveSparseWeightedLeastSquares(
        design: FFICSRMatrix,
        response: [Double],
        weights: [Double],
        maxIterations: Int,
        tolerance: Double
    ) throws -> FFISparseStatisticalSolveResult {
        do {
            let result = try NCBindings.solveSparseWeightedLeastSquares(
                design: makeFfiCSRMatrix(design),
                response: response,
                weights: weights,
                maxIterations: try ffiUInt64(maxIterations, name: "maxIterations"),
                tolerance: tolerance
            )
            return FFISparseStatisticalSolveResult(result)
        } catch {
            throw Self.translate(error)
        }
    }

    /// Runs the portable CSR CGLS solve for
    /// `min Σ wᵢ(yᵢ - xᵢᵀβ)² + λ‖Pβ‖²` without materializing normal
    /// equations. `penalty` must have one column per design coefficient.
    public static func solveSparsePenalizedWeightedLeastSquares(
        design: FFICSRMatrix,
        response: [Double],
        weights: [Double],
        penalty: FFICSRMatrix,
        penaltyWeight: Double,
        maxIterations: Int,
        tolerance: Double
    ) throws -> FFISparseStatisticalSolveResult {
        do {
            let result = try NCBindings.solveSparsePenalizedWeightedLeastSquares(
                design: makeFfiCSRMatrix(design),
                response: response,
                weights: weights,
                penalty: makeFfiCSRMatrix(penalty),
                penaltyWeight: penaltyWeight,
                maxIterations: try ffiUInt64(maxIterations, name: "maxIterations"),
                tolerance: tolerance
            )
            return FFISparseStatisticalSolveResult(result)
        } catch {
            throw Self.translate(error)
        }
    }

    public static func solveSparseConjugateGradient(
        matrix: FFICSRMatrix, rhs: [Double], options: FFILinearSolveOptions
    ) throws -> FFILinearSolveResult {
        do {
            return FFILinearSolveResult(try NCBindings.solveSparseConjugateGradient(
                matrix: makeFfiCSRMatrix(matrix), rhs: rhs, options: try makeLinearOptions(options)))
        } catch { throw Self.translate(error) }
    }

    public static func solveSparseBiCGSTAB(
        matrix: FFICSRMatrix, rhs: [Double], options: FFILinearSolveOptions
    ) throws -> FFILinearSolveResult {
        do {
            return FFILinearSolveResult(try NCBindings.solveSparseBicgstab(
                matrix: makeFfiCSRMatrix(matrix), rhs: rhs, options: try makeLinearOptions(options)))
        } catch { throw Self.translate(error) }
    }

    public static func solveSparseGMRES(
        matrix: FFICSRMatrix, rhs: [Double], options: FFILinearSolveOptions, restart: Int
    ) throws -> FFILinearSolveResult {
        do {
            return FFILinearSolveResult(try NCBindings.solveSparseGmres(
                matrix: makeFfiCSRMatrix(matrix), rhs: rhs,
                options: try makeLinearOptions(options),
                restart: try ffiUInt64(restart, name: "restart")))
        } catch { throw Self.translate(error) }
    }

    public static func solveSparseLU(
        matrix: FFICSRMatrix, rhs: [Double], dropTolerance: Double = 0
    ) throws -> FFISparseDirectResult {
        do {
            return FFISparseDirectResult(try NCBindings.solveSparseLu(
                matrix: makeFfiCSRMatrix(matrix), rhs: rhs, dropTolerance: dropTolerance))
        } catch { throw Self.translate(error) }
    }

    public static func solveSparseCholesky(
        matrix: FFICSRMatrix, rhs: [Double], dropTolerance: Double = 0
    ) throws -> FFISparseDirectResult {
        do {
            return FFISparseDirectResult(try NCBindings.solveSparseCholesky(
                matrix: makeFfiCSRMatrix(matrix), rhs: rhs, dropTolerance: dropTolerance))
        } catch { throw Self.translate(error) }
    }

    private static func makeLinearOptions(_ options: FFILinearSolveOptions) throws
        -> FfiLinearSolveOptions {
        FfiLinearSolveOptions(
            maxIterations: try ffiUInt64(options.maxIterations, name: "maxIterations"),
            tolerance: options.tolerance, initialSolution: options.initialSolution,
            preconditioner: options.preconditioner.generated)
    }

    private static func makeFfiCSRMatrix(_ matrix: FFICSRMatrix) throws -> FfiCsrMatrixF64 {
        FfiCsrMatrixF64(
            rows: try ffiUInt32(matrix.rows, name: "rows"),
            cols: try ffiUInt32(matrix.cols, name: "cols"),
            rowPtr: try matrix.rowPointers.map { try ffiUInt32($0, name: "row pointer") },
            colIndices: try matrix.columnIndices.map { try ffiUInt32($0, name: "column index") },
            values: matrix.values
        )
    }

    private static func ffiUInt32(_ value: Int, name: String) throws -> UInt32 {
        guard let converted = UInt32(exactly: value) else {
            throw FFIError.dimensionMismatch("\(name) must be in 0...\(UInt32.max)")
        }
        return converted
    }

    private static func ffiUInt64(_ value: Int, name: String) throws -> UInt64 {
        guard let converted = UInt64(exactly: value) else {
            throw FFIError.dimensionMismatch("\(name) must be non-negative")
        }
        return converted
    }

    /// Translates the generated `FfiError` into this file's stable
    /// `FFIError`. Isolated in one place so `NumericCore`/
    /// `NumericCoreSparse` never need to know about the generated error
    /// type's exact shape.
    static func translate(_ error: Error) -> FFIError {
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
public struct FFIBound: Sendable, Hashable {
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
    /// Mirrors `nc-ffi::FfiProblem.is_integer`. Empty means "all
    /// continuous" (the Rust side treats an empty list this way too —
    /// see `to_domain_problem`'s comment there) — defaults to `[]` so
    /// existing call sites built before this field existed keep
    /// compiling and behaving identically.
    public let isInteger: [Bool]

    public init(
        objective: [Double],
        constraintRows: Int,
        constraintCols: Int,
        constraintRowPointers: [Int],
        constraintColumnIndices: [Int],
        constraintValues: [Double],
        rowBounds: [FFIBound],
        varBounds: [FFIBound],
        isInteger: [Bool] = []
    ) {
        self.objective = objective
        self.constraintRows = constraintRows
        self.constraintCols = constraintCols
        self.constraintRowPointers = constraintRowPointers
        self.constraintColumnIndices = constraintColumnIndices
        self.constraintValues = constraintValues
        self.rowBounds = rowBounds
        self.varBounds = varBounds
        self.isInteger = isInteger
    }
}

/// Mirrors `nc-ffi::FfiSolveStatus`. See the naming caveat on
/// `FFIError`'s doc comment above — this is the one place that
/// depends on the *unconfirmed* extension of the PascalCase-enum-case
/// evidence.
public enum FFISolveStatus: Sendable, Hashable {
    case optimal
    case infeasible
    case unbounded
    case iterationLimit
}

/// Mirrors `nc-ffi::FfiSolution`.
public struct FFISolution: Sendable, Hashable {
    public let variableValues: [Double]
    public let objectiveValue: Double
    public let status: FFISolveStatus
}

public struct FFISimplexOptions: Sendable, Hashable {
    public var maxIterations: UInt64
    public var tolerance: Double
    public init(maxIterations: UInt64 = 10_000, tolerance: Double = 1e-9) {
        self.maxIterations = maxIterations
        self.tolerance = tolerance
    }
}

public struct FFIInteriorPointOptions: Sendable, Hashable {
    public var maxIterations: UInt64
    public var tolerance: Double
    public var sigma: Double
    public var bigBound: Double
    public var stepFraction: Double
    public init(maxIterations: UInt64 = 200, tolerance: Double = 1e-8,
                sigma: Double = 0.1, bigBound: Double = 1e12,
                stepFraction: Double = 0.995) {
        self.maxIterations = maxIterations
        self.tolerance = tolerance
        self.sigma = sigma
        self.bigBound = bigBound
        self.stepFraction = stepFraction
    }
}

public struct FFIBranchAndBoundOptions: Sendable, Hashable {
    public var maxNodes: UInt64
    public var integerTolerance: Double
    public init(maxNodes: UInt64 = 10_000, integerTolerance: Double = 1e-6) {
        self.maxNodes = maxNodes
        self.integerTolerance = integerTolerance
    }
}

public struct FFIMILPSolveReport: Sendable, Hashable {
    public let solution: FFISolution
    public let nodesExplored: UInt64
    public let bestBound: Double?
    public let absoluteGap: Double?
    public let relativeGap: Double?
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

    public static func solveLPSimplex(
        _ problem: FFIProblem, options: FFISimplexOptions
    ) throws -> FFISolution {
        do {
            return makeFFISolution(try solveLpSimplexWithOptions(
                problem: makeFfiProblem(problem),
                options: FfiSimplexOptions(
                    maxIterations: options.maxIterations, tolerance: options.tolerance
                )
            ))
        } catch { throw Self.translate(error) }
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

    public static func solveLPInteriorPoint(
        _ problem: FFIProblem, options: FFIInteriorPointOptions
    ) throws -> FFISolution {
        do {
            return makeFFISolution(try solveLpInteriorPointWithOptions(
                problem: makeFfiProblem(problem),
                options: FfiInteriorPointOptions(
                    maxIterations: options.maxIterations, tolerance: options.tolerance,
                    sigma: options.sigma, bigBound: options.bigBound,
                    stepFraction: options.stepFraction
                )
            ))
        } catch { throw Self.translate(error) }
    }

    /// Solves via `nc-optimize::BranchAndBoundSolver` (MILP —
    /// LP-relaxation branch-and-bound). `problem.isInteger` selects
    /// which variables are integer-restricted; empty means "all
    /// continuous" (see `FFIProblem.isInteger`'s doc comment), which
    /// degrades to a plain LP solve with no branching — harmless, but
    /// if that's actually what's wanted, calling `solveLPSimplex`
    /// directly is the more direct route.
    public static func solveMILP(_ problem: FFIProblem) throws -> FFISolution {
        do {
            let result = try solveMilpBranchAndBound(problem: makeFfiProblem(problem))
            return makeFFISolution(result)
        } catch {
            throw Self.translate(error)
        }
    }

    public static func solveMILP(
        _ problem: FFIProblem, options: FFIBranchAndBoundOptions
    ) throws -> FFIMILPSolveReport {
        do {
            let result = try solveMilpBranchAndBoundWithOptions(
                problem: makeFfiProblem(problem),
                options: FfiBranchAndBoundOptions(
                    maxNodes: options.maxNodes,
                    integerTolerance: options.integerTolerance
                )
            )
            return FFIMILPSolveReport(
                solution: makeFFISolution(result.solution),
                nodesExplored: result.nodesExplored,
                bestBound: result.bestBound,
                absoluteGap: result.absoluteGap,
                relativeGap: result.relativeGap
            )
        } catch { throw Self.translate(error) }
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
            varBounds: problem.varBounds.map { FfiBound(lower: $0.lower, upper: $0.upper) },
            isInteger: problem.isInteger
        )
    }

    private static func makeFFISolution(_ result: FfiSolution) -> FFISolution {
        let status: FFISolveStatus
        switch result.status {
        case .optimal: status = .optimal
        case .infeasible: status = .infeasible
        case .unbounded: status = .unbounded
        case .iterationLimit: status = .iterationLimit
        }
        return FFISolution(
            variableValues: result.variableValues,
            objectiveValue: result.objectiveValue,
            status: status
        )
    }
}
