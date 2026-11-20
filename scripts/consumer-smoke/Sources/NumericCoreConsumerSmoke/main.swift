import NumericCore
import NumericCoreOptimization
import NumericCoreSparse

let matrix = try SparseMatrix<Double>(
    rows: 2, cols: 2, rowPointers: [0, 1, 2], columnIndices: [0, 1], values: [2, 3])
let product = try matrix.multiplying(Vector([4.0, 5.0]))
precondition(product == Vector([8.0, 15.0]), "unexpected sparse matrix product")

let solve = try LBFGS.minimize(initial: [0.0]) { point in
    let delta = point[0] - 2
    return (value: delta * delta, gradient: [2 * delta])
}
precondition(abs(solve.point[0] - 2) < 1e-8, "unexpected minimizer")
print("NumericCore consumer smoke check passed")
