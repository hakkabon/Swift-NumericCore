import XCTest
@testable import NumericCore
@testable import NumericCoreAccelerate

/// Correctness-testing harness: diffs backend output against
/// `RustFallbackBackend`, which is treated as the ground truth (it's the
/// simplest implementation, most amenable to manual verification).
final class BackendDiffTests: XCTestCase {

    override func tearDown() {
        // Every test in this file mutates Dispatcher's global registered
        // backends — reset so later test files (which assume the default
        // empty list) aren't affected by run order.
        Dispatcher.registeredBackends = []
        super.tearDown()
    }

    private func randomMatrix(rows: Int, cols: Int, seed: inout UInt64) throws -> Matrix<Double> {
        var storage: [Double] = []
        storage.reserveCapacity(rows * cols)
        for _ in 0..<(rows * cols) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            storage.append(Double(seed >> 40) / Double(1 << 24))
        }
        return try Matrix(rows: rows, cols: cols, storage: storage)
    }

    func testFallbackMatmulIsSelfConsistentAcrossSizes() throws {
        var seed: UInt64 = 42
        for (m, k, n) in [(3, 3, 3), (5, 2, 4), (1, 10, 1)] {
            let a = try randomMatrix(rows: m, cols: k, seed: &seed)
            let b = try randomMatrix(rows: k, cols: n, seed: &seed)

            Dispatcher.registeredBackends = []
            let first = try a * b

            Dispatcher.registeredBackends = []
            let second = try a * b

            XCTAssertEqual(first, second, "fallback backend should be deterministic for shape \(m)x\(k)x\(n)")
        }
    }

    /// The real diff: `AccelerateBackend.matmul` (cblas_dgemm) against
    /// `RustFallbackBackend`'s naive triple loop, across several shapes
    /// including non-square ones (to catch a transposed-dimension bug,
    /// which a square-only test would miss).
    func testAccelerateMatmulAgreesWithFallback() throws {
        var seed: UInt64 = 1234
        for (m, k, n) in [(3, 3, 3), (5, 2, 4), (1, 10, 1), (17, 9, 4), (1, 1, 1)] {
            let a = try randomMatrix(rows: m, cols: k, seed: &seed)
            let b = try randomMatrix(rows: k, cols: n, seed: &seed)

            Dispatcher.registeredBackends = []
            let fallbackResult = try a * b

            Dispatcher.registeredBackends = [AccelerateBackend.self]
            let accelerateResult = try a * b

            XCTAssertEqual(fallbackResult.rows, accelerateResult.rows)
            XCTAssertEqual(fallbackResult.cols, accelerateResult.cols)
            for i in 0..<fallbackResult.storage.count {
                XCTAssertEqual(
                    fallbackResult.storage[i], accelerateResult.storage[i],
                    accuracy: 1e-9,
                    "mismatch at flat index \(i) for shape \(m)x\(k)x\(n)"
                )
            }
        }
    }

    /// Confirms `Dispatcher` actually routes to `AccelerateBackend` when
    /// registered, rather than this test accidentally passing because
    /// both backends silently agree by falling back to the same code path.
    func testAccelerateBackendIsActuallyChosenWhenRegistered() {
        let chosen = DispatchPolicy.default.chooseBackend(
            for: .matmul, elementCount: 9, scalarTypeName: "Double", sparse: false,
            candidates: [AccelerateBackend.self]
        )
        XCTAssertTrue(chosen == AccelerateBackend.self)
    }
}
