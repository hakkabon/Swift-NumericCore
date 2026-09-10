import Metal
import MetalPerformanceShaders
import NumericCore

/// GPU backend via Metal Performance Shaders.
///
/// **Scaffold** — deferred behind lean-v1 scoping
/// (`docs/decisions/0003-decomposition-scope.md`'s sibling reasoning
/// applies here too: get Accelerate working and proven first). This type
/// exists now so `DispatchPolicy`/`Dispatcher` have a real second backend
/// to route between once it's implemented, rather than that plumbing
/// being designed against only one concrete backend and needing rework
/// later.
///
/// When picking this up: `isAvailable()` needs a real `MTLCreateSystemDefaultDevice()`
/// check (cached statically — see `Backend.isAvailable()`'s doc comment
/// on why this must stay cheap), and `gpuThreshold` in `DispatchPolicy`
/// needs real numbers from `nc-bench`-style benchmarking comparing this
/// against `AccelerateBackend` at several matrix sizes on real hardware.
public enum MPSBackend: Backend {
    public static let identifier = "mps"
    public static let device: ComputeDevice = .gpu
    public static let capabilities: BackendCapabilities = []

    public static func isAvailable() -> Bool {
        false // Flip to a real device check once matmul is implemented.
    }
}
