import NumericCore
import NumericCoreSparse

public enum PresolveError: Error, Equatable {
    case noObjective
    case duplicateVariableName(String)
    case invalidVariableBound(index: Int)
    case invalidVariableReference(Int)
    case nonFiniteModelValue
    case nonlinearExpressionRequiresNonlinearCompiler
}

extension Model {
    /// Compiles this `Model` into a `CompiledProblem` — a dense
    /// objective vector, a `SparseMatrix` constraint matrix, and
    /// row/variable bounds, ready to hand to `nc-optimize::Solver` via
    /// `NCBindings`.
    ///
    /// Throws `.noObjective` if no `minimize`/`maximize` statement was
    /// ever parsed — every LP needs one, and there's no sensible default
    /// to fall back to.
    public func compile() throws -> CompiledProblem {
        guard let objective else {
            throw PresolveError.noObjective
        }
        guard objective.algebraicExpression?.affine != nil
                || objective.algebraicExpression == nil,
              constraints.allSatisfy({ constraint in
                  (constraint.algebraicLHS?.affine != nil || constraint.algebraicLHS == nil)
                      && (constraint.algebraicRHS?.affine != nil || constraint.algebraicRHS == nil)
              }) else {
            throw PresolveError.nonlinearExpressionRequiresNonlinearCompiler
        }

        let variableCount = variableNames.count
        var seenNames = Set<String>()
        for name in variableNames where !seenNames.insert(name).inserted {
            throw PresolveError.duplicateVariableName(name)
        }
        for (index, bound) in variableBounds.enumerated() {
            guard bound.lower?.isFinite ?? true,
                  bound.upper?.isFinite ?? true,
                  !((bound.lower.map { lower in bound.upper.map { lower > $0 } ?? false }) ?? false)
            else {
                throw PresolveError.invalidVariableBound(index: index)
            }
        }
        guard objective.expression.constant.isFinite else {
            throw PresolveError.nonFiniteModelValue
        }

        var objectiveCoefficients = [Double](repeating: 0, count: variableCount)
        for (variableIndex, coefficient) in objective.expression.coefficients {
            guard objectiveCoefficients.indices.contains(variableIndex) else {
                throw PresolveError.invalidVariableReference(variableIndex)
            }
            guard coefficient.isFinite else { throw PresolveError.nonFiniteModelValue }
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
            guard combinedConstant.isFinite else { throw PresolveError.nonFiniteModelValue }
            let rhsValue = -combinedConstant

            // Sorted ascending by variable index — required for valid
            // CSR row structure (SparseMatrix assumes column indices
            // within a row are usable as given; sorting here keeps rows
            // in a canonical, deterministic order regardless of the
            // (dictionary, so unordered) iteration order of `combined`).
            for variableIndex in combined.keys.sorted() {
                let coefficient = combined[variableIndex]!
                guard (0..<variableCount).contains(variableIndex) else {
                    throw PresolveError.invalidVariableReference(variableIndex)
                }
                guard coefficient.isFinite else { throw PresolveError.nonFiniteModelValue }
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
            variableNames: variableNames,
            objective: Vector(objectiveCoefficients),
            constraints: constraintMatrix,
            variableLowerBounds: variableBounds.map { $0.lower },
            variableUpperBounds: variableBounds.map { $0.upper },
            rowBounds: rowBounds,
            variableIsInteger: variableIsInteger,
            objectiveSign: objectiveSign,
            objectiveConstant: objective.expression.constant
        )
    }
}
