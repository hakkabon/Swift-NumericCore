import NumericCore

/// Stable array-oriented solver boundary for statistical clients.
///
/// Statistical packages naturally exchange row-major design matrices and
/// arrays, while `NumericCore` stores dense matrices in column-major form.
/// This type owns that conversion and normalizes invalid shapes, LAPACK
/// failures, and rank/definiteness verdicts to `nil`. It lets clients share a
/// numerical contract without importing `Matrix`/`Vector` conversion details
/// at each LOESS, IRLS, or regression call site.
public enum StatisticalSolver {
    /// Solve `min ‖Xβ − y‖₂` by QR.
    ///
    /// Returns nil for invalid shapes, underdetermined/rank-deficient designs,
    /// or a backend failure. Rows are supplied in conventional row-major form.
    public static func leastSquares(design: [[Double]], response: [Double]) -> [Double]? {
        do {
            let matrix = try Matrix<Double>(rows: design)
            let vector = Vector(response)
            guard let solution = try AccelerateBackend.leastSquares(
                design: matrix, response: vector
            ) else { return nil }
            return solution.storage
        } catch {
            return nil
        }
    }

    /// Solve a general square system by QR with the shared rank threshold.
    ///
    /// Returns nil for invalid shapes, singular systems, or backend failures.
    public static func solve(_ matrix: [[Double]], _ response: [Double]) -> [Double]? {
        do {
            let coefficientMatrix = try Matrix<Double>(rows: matrix)
            let vector = Vector(response)
            guard let solution = try AccelerateBackend.solve(coefficientMatrix, vector) else {
                return nil
            }
            return solution.storage
        } catch {
            return nil
        }
    }

    /// Solve a symmetric positive-definite system by Cholesky.
    ///
    /// The caller must supply a symmetric-by-construction matrix. Returns nil
    /// for invalid shapes, non-positive-definite systems, or backend failures.
    public static func solveSPD(_ matrix: [[Double]], _ response: [Double]) -> [Double]? {
        do {
            let coefficientMatrix = try Matrix<Double>(rows: matrix)
            let vector = Vector(response)
            guard let solution = try AccelerateBackend.solveSPD(coefficientMatrix, vector) else {
                return nil
            }
            return solution.storage
        } catch {
            return nil
        }
    }
}
