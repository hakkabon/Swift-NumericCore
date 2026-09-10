import XCTest
@testable import NumericCore

final class DispatchPolicyTests: XCTestCase {
    /// A fake backend used only to exercise `DispatchPolicy` routing
    /// logic without depending on `NumericCoreAccelerate`/`MPS`.
    private enum FakeGPUBackend: Backend {
        static let identifier = "fake-gpu"
        static let device: ComputeDevice = .gpu
        static let capabilities: BackendCapabilities = [.matmul]
        static func isAvailable() -> Bool { true }
    }

    private enum FakeUnavailableBackend: Backend {
        static let identifier = "fake-unavailable"
        static let device: ComputeDevice = .cpu
        static let capabilities: BackendCapabilities = [.matmul]
        static func isAvailable() -> Bool { false }
    }

    func testFallsBackWhenNoCandidatesGiven() {
        let policy = DispatchPolicy()
        let chosen = policy.chooseBackend(
            for: .matmul, elementCount: 100, scalarTypeName: "Double", sparse: false, candidates: []
        )
        XCTAssertTrue(chosen == RustFallbackBackend.self)
    }

    func testSkipsUnavailableBackend() {
        let policy = DispatchPolicy()
        let chosen = policy.chooseBackend(
            for: .matmul, elementCount: 100, scalarTypeName: "Double", sparse: false,
            candidates: [FakeUnavailableBackend.self]
        )
        XCTAssertTrue(chosen == RustFallbackBackend.self)
    }

    func testGPUBackendSkippedBelowThreshold() {
        var policy = DispatchPolicy()
        policy.gpuThreshold = 1_000
        let chosen = policy.chooseBackend(
            for: .matmul, elementCount: 10, scalarTypeName: "Double", sparse: false,
            candidates: [FakeGPUBackend.self]
        )
        XCTAssertTrue(chosen == RustFallbackBackend.self)
    }

    func testGPUBackendChosenAboveThreshold() {
        var policy = DispatchPolicy()
        policy.gpuThreshold = 1_000
        let chosen = policy.chooseBackend(
            for: .matmul, elementCount: 10_000, scalarTypeName: "Double", sparse: false,
            candidates: [FakeGPUBackend.self]
        )
        XCTAssertTrue(chosen == FakeGPUBackend.self)
    }

    func testSparseAlwaysRoutesToFallbackRegardlessOfCandidates() {
        let policy = DispatchPolicy()
        let chosen = policy.chooseBackend(
            for: .matmul, elementCount: 10_000, scalarTypeName: "Double", sparse: true,
            candidates: [FakeGPUBackend.self]
        )
        XCTAssertTrue(chosen == RustFallbackBackend.self)
    }
}
