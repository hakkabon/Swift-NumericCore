import NumericCore
import NumericCoreSparse

/// Bridges `SparseMatrix` to graph-theoretic structures — adjacency
/// matrices and graph Laplacians — for consumption by (or construction
/// from) the existing NetworkGraph/Layout ecosystem.
///
/// This module is deliberately thin: it does not reimplement graph
/// algorithms (those belong in NetworkGraph) or layout (Layout already
/// does Sugiyama-style layout in Rust). Its only job is the seam —
/// turning edge lists into the sparse matrices this package's solvers
/// understand, and vice versa.
///
/// **Scaffold**: only the adjacency-matrix construction is implemented.
/// The graph Laplacian (`D - A`, useful for spectral layout methods) is
/// the natural next addition once there's a concrete consumer for it —
/// see the module-level reasoning in `nc-decomp`/`nc-optimize` for why
/// this project prefers waiting for a real need over building ahead of
/// one.
public enum GraphBridge {
    /// Build an unweighted adjacency matrix from a 0-indexed edge list.
    /// `undirected: true` (the default) inserts both `(u, v)` and `(v, u)`.
    public static func adjacencyMatrix(
        nodeCount: Int,
        edges: [(Int, Int)],
        undirected: Bool = true
    ) throws -> SparseMatrix<Double> {
        var perRow: [[Int: Double]] = Array(repeating: [:], count: nodeCount)
        for (u, v) in edges {
            guard u >= 0, u < nodeCount, v >= 0, v < nodeCount else {
                throw NCError.dimensionMismatch("adjacencyMatrix: edge (\(u), \(v)) out of bounds for \(nodeCount) nodes")
            }
            perRow[u][v] = 1.0
            if undirected {
                perRow[v][u] = 1.0
            }
        }

        var rowPointers = [Int](repeating: 0, count: nodeCount + 1)
        var columnIndices: [Int] = []
        var values: [Double] = []

        for row in 0..<nodeCount {
            let sorted = perRow[row].sorted { $0.key < $1.key }
            for (col, value) in sorted {
                columnIndices.append(col)
                values.append(value)
            }
            rowPointers[row + 1] = columnIndices.count
        }

        return try SparseMatrix(
            rows: nodeCount,
            cols: nodeCount,
            rowPointers: rowPointers,
            columnIndices: columnIndices,
            values: values
        )
    }
}
