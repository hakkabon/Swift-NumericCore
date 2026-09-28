import XCTest
@testable import NumericCore
@testable import NumericCoreSparse
@testable import NumericCoreGraph

final class SparseMatrixTests: XCTestCase {
    /// [[1, 0, 2],
    ///  [0, 3, 0]]
    private func sample() throws -> SparseMatrix<Double> {
        try SparseMatrix(
            rows: 2, cols: 3,
            rowPointers: [0, 2, 3],
            columnIndices: [0, 2, 1],
            values: [1, 2, 3]
        )
    }

    func testSpMVMatchesHandComputation() throws {
        let m = try sample()
        let result = try m.multiplying(Vector([1, 1, 1]))
        XCTAssertEqual(result, Vector([3, 3]))
    }

    func testRejectsBadRowPointerCount() {
        XCTAssertThrowsError(
            try SparseMatrix<Double>(rows: 2, cols: 3, rowPointers: [0, 2], columnIndices: [0], values: [1])
        )
    }

    func testSpMVRejectsDimensionMismatch() throws {
        let m = try sample()
        XCTAssertThrowsError(try m.multiplying(Vector([1, 1])))
    }

    func testCoordinateAssemblyCanonicalizesDuplicatesAndZeros() throws {
        let matrix = try SparseMatrix<Double>(rows: 2, cols: 3, entries: [
            SparseEntry(row: 1, column: 2, value: 4),
            SparseEntry(row: 0, column: 1, value: 3),
            SparseEntry(row: 1, column: 0, value: 2),
            SparseEntry(row: 0, column: 1, value: -3),
            SparseEntry(row: 1, column: 2, value: 1),
        ])
        XCTAssertEqual(matrix.csrRowPointers, [0, 0, 2])
        XCTAssertEqual(matrix.csrColumnIndices, [0, 2])
        XCTAssertEqual(matrix.csrValues, [2, 5])
    }

    func testTransposeRoundTripAndProduct() throws {
        let matrix = try sample()
        let transposed = try matrix.transposed()
        XCTAssertEqual(try transposed.multiplying(Vector([4, 5])), Vector([4, 15, 8]))
        let roundTrip = try transposed.transposed()
        XCTAssertEqual(roundTrip.csrRowPointers, matrix.csrRowPointers)
        XCTAssertEqual(roundTrip.csrColumnIndices, matrix.csrColumnIndices)
        XCTAssertEqual(roundTrip.csrValues, matrix.csrValues)
    }

    func testRejectsMalformedCSRStructureAtConstruction() {
        XCTAssertThrowsError(try SparseMatrix<Double>(
            rows: 2, cols: 1, rowPointers: [0, 2, 1],
            columnIndices: [0], values: [1]
        ))
    }
}

final class GraphBridgeTests: XCTestCase {
    func testUndirectedAdjacencyMatrixIsSymmetric() throws {
        // Triangle: 0-1, 1-2, 0-2
        let adjacency = try GraphBridge.adjacencyMatrix(nodeCount: 3, edges: [(0, 1), (1, 2), (0, 2)])
        // Every node has degree 2 in a triangle.
        let ones = Vector<Double>(repeating: 1, count: 3)
        let degrees = try adjacency.multiplying(ones)
        XCTAssertEqual(degrees, Vector([2, 2, 2]))
    }

    func testOutOfBoundsEdgeThrows() {
        XCTAssertThrowsError(try GraphBridge.adjacencyMatrix(nodeCount: 2, edges: [(0, 5)]))
    }
}
