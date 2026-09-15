import NumericCore
import NumericCoreSparse

public enum PresolveError: Error, Equatable {
    case noObjective
}

extension Model {
    /// Compiles this `Model` into a `CompiledProblem` — a dense
    /// objective vector, a `SparseMatrix` constraint matrix, and
    /// row/variable bounds, ready to hand to `nc-optimize::Solver` via
    /// `NCBindings` (not yet wired — see `Model.swift`'s module docs).
    ///
    /// Throws `.noObjective` if no `minimize`/`maximize` statement was
    /// ever parsed — every LP needs one, and there's no sensible default
    /// to fall back to.
    public func compile() throws -> CompiledProblem {
        guard let objective else {
            throw PresolveError.noObjective
        }

        let variableCount = variableNames.count

        var objectiveCoefficients = [Double](repeating: 0, count: variableCount)
        for (variableIndex, coefficient) in objective.expression.coefficients {
            objectiveCoefficients[variableIndex] = coefficient
        }

        // nc_optimize::Problem (ADR 0004) only expresses `minimize
        // c^T x` — a `maximize` objective is negated here so every
        // CompiledProblem is uniformly in minimize form. objectiveSign
        // records which happened so a caller can flip the solver's
        // returned objective value back to the model's original sense.
        let objectiveSign: Double = objective.sense == .maximize ? -1 : 1
        if objective.sense == .maximize {
            for i in 0..<variableCount {
                objectiveCoefficients[i] *= -1
            }
        }

        var rowPointers: [Int] = [0]
        var columnIndices: [Int] = []
        var values: [Double] = []
        var rowBounds: [(lower: Double?, upper: Double?)] = []
        rowBounds.reserveCapacity(constraints.count)

        for constraint in constraints {
            // Move everything to one side: (lhs - rhs) `relation` 0,
            // i.e. combinedCoefficients·x `relation` -combinedConstant.
            var combined = constraint.lhs.coefficients
            for (variableIndex, coefficient) in constraint.rhs.coefficients {
                combined[variableIndex, default: 0] -= coefficient
            }
            let combinedConstant = constraint.lhs.constant - constraint.rhs.constant
            let rhsValue = -combinedConstant

            // Sorted ascending by variable index — required for valid
            // CSR row structure (SparseMatrix assumes column indices
            // within a row are usable as given; sorting here keeps rows
            // in a canonical, deterministic order regardless of the
            // (dictionary, so unordered) iteration order of `combined`).
            for variableIndex in combined.keys.sorted() {
                let coefficient = combined[variableIndex]!
                guard coefficient != 0 else { continue }
                columnIndices.append(variableIndex)
                values.append(coefficient)
            }
            rowPointers.append(columnIndices.count)

            switch constraint.relation {
            case .lessThanOrEqual:
                rowBounds.append((lower: nil, upper: rhsValue))
            case .greaterThanOrEqual:
                rowBounds.append((lower: rhsValue, upper: nil))
            case .equal:
                rowBounds.append((lower: rhsValue, upper: rhsValue))
            }
        }

        let constraintMatrix = try SparseMatrix<Double>(
            rows: constraints.count,
            cols: variableCount,
            rowPointers: rowPointers,
            columnIndices: columnIndices,
            values: values
        )

        return CompiledProblem(
            objective: Vector(objectiveCoefficients),
            constraints: constraintMatrix,
            variableLowerBounds: variableBounds.map { $0.lower },
            variableUpperBounds: variableBounds.map { $0.upper },
            rowBounds: rowBounds,
            objectiveSign: objectiveSign
        )
    }
}
