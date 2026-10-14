import Foundation
import NumericCore
import NumericCoreSparse

public struct FEMModalResult {
    public let angularFrequencies: [Double]
    public let frequenciesHz: [Double]
    /// Full-DOF, mass-normalized mode shapes. Constrained entries are zero.
    public let modeShapes: [[Double]]
    public let maximumRelativeResidual: Double
    public let maximumMassOrthogonalityError: Double
    public let mass: SparseMatrix<Double>
    public let stiffness: SparseMatrix<Double>
}

public struct FEMDynamicOptions: Sendable, Hashable {
    public let timeStep: Double
    public let steps: Int
    /// Rayleigh coefficient in `C = alpha M + beta K`.
    public let massDamping: Double
    /// Rayleigh coefficient in `C = alpha M + beta K`.
    public let stiffnessDamping: Double
    public init(timeStep: Double, steps: Int, massDamping: Double = 0,
                stiffnessDamping: Double = 0) {
        self.timeStep = timeStep; self.steps = steps
        self.massDamping = massDamping; self.stiffnessDamping = stiffnessDamping
    }
}

public struct FEMDynamicState: Sendable, Hashable {
    public let time: Double
    public let displacement: [Double]
    public let velocity: [Double]
    public let acceleration: [Double]
    public let kineticEnergy: Double
    public let strainEnergy: Double
}

public struct FEMDynamicResult {
    public let states: [FEMDynamicState]
    public let maximumRelativeEquilibriumResidual: Double
    public let mass: SparseMatrix<Double>
    public let stiffness: SparseMatrix<Double>
}

extension TrussFEMModel {
    /// Computes the lowest flexible modes of `K phi = lambda M phi`.
    public func modalAnalysis(modeCount: Int) throws -> FEMModalResult {
        let (stiffness, mass) = try assembleDynamicMatrices()
        let free = try dynamicFreeDOFs()
        guard modeCount > 0, modeCount <= free.count else {
            throw femDynamicsInvalid("mode count must be between one and the number of free DOFs")
        }
        let k = femDenseSubmatrix(stiffness, free), m = femDenseSubmatrix(mass, free)
        let lower = try femDenseCholesky(m)
        var transformed = Array(repeating: Array(repeating: 0.0, count: free.count), count: free.count)
        for column in free.indices {
            var unit = [Double](repeating: 0, count: free.count); unit[column] = 1
            let right = femSolveUpper(lower, unit)
            let result = femSolveLower(lower, femDenseProduct(k, right))
            for row in free.indices { transformed[row][column] = result[row] }
        }
        femSymmetrize(&transformed)
        let (eigenvalues, eigenvectors) = try femJacobiEigen(transformed)
        let order = eigenvalues.indices.filter { eigenvalues[$0] > 1e-12 }
            .sorted { eigenvalues[$0] < eigenvalues[$1] }
        guard order.count >= modeCount else {
            throw femDynamicsInvalid("constrained structure contains a rigid-body mechanism")
        }
        var shapes: [[Double]] = [], omegas: [Double] = [], maxResidual = 0.0
        for index in order.prefix(modeCount) {
            let reduced = femSolveUpper(lower, eigenvectors.map { $0[index] })
            var shape = [Double](repeating: 0, count: 2 * nodes.count)
            for (local, dof) in free.enumerated() { shape[dof] = reduced[local] }
            let kp = femSparseProduct(stiffness, shape), mp = femSparseProduct(mass, shape)
            let lambda = eigenvalues[index]
            let numerator = sqrt(free.reduce(0) { $0 + pow(kp[$1] - lambda * mp[$1], 2) })
            let denominator = max(1, sqrt(free.reduce(0) { $0 + kp[$1] * kp[$1] }))
            maxResidual = max(maxResidual, numerator / denominator)
            shapes.append(shape); omegas.append(sqrt(lambda))
        }
        var orthogonality = 0.0
        for i in shapes.indices { for j in shapes.indices {
            let product = zip(shapes[i], femSparseProduct(mass, shapes[j])).reduce(0) { $0 + $1.0 * $1.1 }
            orthogonality = max(orthogonality, abs(product - (i == j ? 1 : 0)))
        }}
        return .init(angularFrequencies: omegas,
                     frequenciesHz: omegas.map { $0 / (2 * .pi) }, modeShapes: shapes,
                     maximumRelativeResidual: maxResidual,
                     maximumMassOrthogonalityError: orthogonality,
                     mass: mass, stiffness: stiffness)
    }

    /// Integrates `M u'' + C u' + K u = f(t)` with average-acceleration Newmark.
    /// `loadHistory` contains nodal loads at times zero through `steps`.
    public func dynamicResponse(options: FEMDynamicOptions,
                                initialDisplacement: [Double], initialVelocity: [Double],
                                loadHistory: [[FEMNodalLoad]]) throws -> FEMDynamicResult {
        let (stiffness, mass) = try assembleDynamicMatrices(), count = 2 * nodes.count
        guard options.timeStep.isFinite, options.timeStep > 0, options.steps > 0,
              options.massDamping.isFinite, options.massDamping >= 0,
              options.stiffnessDamping.isFinite, options.stiffnessDamping >= 0,
              initialDisplacement.count == count, initialVelocity.count == count,
              (initialDisplacement + initialVelocity).allSatisfy(\.isFinite),
              loadHistory.count == options.steps + 1 else {
            throw femDynamicsInvalid("invalid FEM dynamic configuration")
        }
        let free = try dynamicFreeDOFs()
        guard constraints.allSatisfy({ abs(initialDisplacement[$0.dof]) <= 1e-14 && abs(initialVelocity[$0.dof]) <= 1e-14 }) else {
            throw femDynamicsInvalid("constrained initial displacement and velocity must be zero")
        }
        let k = femDenseSubmatrix(stiffness, free), m = femDenseSubmatrix(mass, free)
        let c = femDenseCombine(m, options.massDamping, k, options.stiffnessDamping)
        let forces = try loadHistory.map { loads -> [Double] in
            var full = [Double](repeating: 0, count: count)
            for load in loads {
                guard full.indices.contains(load.dof), load.value.isFinite else {
                    throw femDynamicsInvalid("invalid dynamic nodal load")
                }
                full[load.dof] += load.value
            }
            return free.map { full[$0] }
        }
        var u = free.map { initialDisplacement[$0] }, v = free.map { initialVelocity[$0] }
        let massFactor = try femDenseCholesky(m)
        var initialRHS = forces[0]
        femSubtract(&initialRHS, femDenseProduct(c, v)); femSubtract(&initialRHS, femDenseProduct(k, u))
        var acceleration = femCholeskySolve(massFactor, initialRHS)
        let dt = options.timeStep, a0 = 4 / (dt * dt), a1 = 2 / dt
        let effective = femDenseCombine(femDenseCombine(k, 1, m, a0), 1, c, a1)
        let effectiveFactor = try femDenseCholesky(effective)
        var states = [femDynamicState(time: 0, u: u, v: v, a: acceleration,
                                      free: free, count: count, m: m, k: k)]
        var maxResidual = 0.0
        for step in 1...options.steps {
            var rhs = forces[step]
            femAdd(&rhs, femDenseProduct(m, zip(zip(u, v), acceleration).map { a0*$0.0.0 + 2*a1*$0.0.1 + $0.1 }))
            femAdd(&rhs, femDenseProduct(c, zip(zip(u, v), acceleration).map { a1*$0.0.0 + $0.0.1 + 0.5*dt*$0.1 }))
            let nextU = femCholeskySolve(effectiveFactor, rhs)
            let nextA = zip(zip(zip(nextU, u), v), acceleration).map { a0*($0.0.0.0-$0.0.0.1)-2*a1*$0.0.1-$0.1 }
            let nextV = zip(zip(v, acceleration), nextA).map { $0.0.0 + 0.5*dt*($0.0.1+$0.1) }
            var residual = femDenseProduct(m, nextA)
            femAdd(&residual, femDenseProduct(c, nextV)); femAdd(&residual, femDenseProduct(k, nextU)); femSubtract(&residual, forces[step])
            maxResidual = max(maxResidual, sqrt(residual.reduce(0) { $0+$1*$1 }) /
                max(1, sqrt(forces[step].reduce(0) { $0+$1*$1 })))
            u = nextU; v = nextV; acceleration = nextA
            states.append(femDynamicState(time: Double(step)*dt, u: u, v: v, a: acceleration,
                                          free: free, count: count, m: m, k: k))
        }
        return .init(states: states, maximumRelativeEquilibriumResidual: maxResidual,
                     mass: mass, stiffness: stiffness)
    }

    private func assembleDynamicMatrices() throws -> (SparseMatrix<Double>, SparseMatrix<Double>) {
        try validate()
        guard materials.allSatisfy({ $0.density > 0 }) else {
            throw femDynamicsInvalid("modal and dynamic analysis require positive material density")
        }
        let count = 2 * nodes.count
        var stiffness: [SparseEntry<Double>] = [], mass: [SparseEntry<Double>] = []
        for element in elements {
            let geometry = try femTrussGeometry(nodes[element.nodes[0]], nodes[element.nodes[1]])
            let material = materials[element.material]
            let direction = [-geometry.cosine, -geometry.sine, geometry.cosine, geometry.sine]
            let dofs = [2*element.nodes[0], 2*element.nodes[0]+1, 2*element.nodes[1], 2*element.nodes[1]+1]
            let k = material.youngModulus * material.area / geometry.length
            let m = material.density * material.area * geometry.length / 6
            for row in 0..<4 { for column in 0..<4 {
                stiffness.append(.init(row: dofs[row], column: dofs[column], value: k*direction[row]*direction[column]))
                let nodeFactor = row/2 == column/2 ? 2.0 : 1.0
                let component = row%2 == column%2 ? 1.0 : 0.0
                mass.append(.init(row: dofs[row], column: dofs[column], value: m*nodeFactor*component))
            }}
        }
        return (try SparseMatrix(rows: count, cols: count, entries: stiffness),
                try SparseMatrix(rows: count, cols: count, entries: mass))
    }

    private func dynamicFreeDOFs() throws -> [Int] {
        guard constraints.allSatisfy({ abs($0.value) <= 1e-14 }) else {
            throw femDynamicsInvalid("modal and dynamic analysis require homogeneous constraints")
        }
        let fixed = Set(constraints.map(\.dof)), free = (0..<2*nodes.count).filter { !fixed.contains($0) }
        guard !free.isEmpty else { throw femDynamicsInvalid("FEM model has no free degrees of freedom") }
        return free
    }
}

private func femSparseProduct(_ matrix: SparseMatrix<Double>, _ vector: [Double]) -> [Double] {
    var result = [Double](repeating: 0, count: matrix.rows)
    for row in 0..<matrix.rows { for index in matrix.csrRowPointers[row]..<matrix.csrRowPointers[row+1] {
        result[row] += matrix.csrValues[index] * vector[matrix.csrColumnIndices[index]]
    }}
    return result
}
private func femDenseSubmatrix(_ matrix: SparseMatrix<Double>, _ indices: [Int]) -> [[Double]] {
    let map = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
    var result = Array(repeating: Array(repeating: 0.0, count: indices.count), count: indices.count)
    for row in 0..<matrix.rows { for index in matrix.csrRowPointers[row]..<matrix.csrRowPointers[row+1] {
        if let i = map[row], let j = map[matrix.csrColumnIndices[index]] { result[i][j] += matrix.csrValues[index] }
    }}
    return result
}
private func femDenseProduct(_ a: [[Double]], _ x: [Double]) -> [Double] { a.map { zip($0,x).reduce(0) { $0+$1.0*$1.1 } } }
private func femDenseCombine(_ a: [[Double]], _ alpha: Double, _ b: [[Double]], _ beta: Double) -> [[Double]] { zip(a,b).map { zip($0,$1).map { alpha*$0+beta*$1 } } }
private func femAdd(_ a: inout [Double], _ b: [Double]) { for i in a.indices { a[i] += b[i] } }
private func femSubtract(_ a: inout [Double], _ b: [Double]) { for i in a.indices { a[i] -= b[i] } }
private func femDenseCholesky(_ a: [[Double]]) throws -> [[Double]] {
    var lower = Array(repeating: Array(repeating: 0.0, count: a.count), count: a.count)
    for i in a.indices { for j in 0...i {
        let value = a[i][j] - (0..<j).reduce(0) { $0 + lower[i][$1]*lower[j][$1] }
        if i == j { guard value.isFinite, value > 1e-14 else { throw femDynamicsInvalid("FEM mass or effective matrix is not positive definite") }; lower[i][j] = sqrt(value) }
        else { lower[i][j] = value/lower[j][j] }
    }}
    return lower
}
private func femSolveLower(_ l: [[Double]], _ b: [Double]) -> [Double] { var x=[Double](repeating:0,count:b.count); for i in b.indices{x[i]=(b[i]-(0..<i).reduce(0){$0+l[i][$1]*x[$1]})/l[i][i]}; return x }
private func femSolveUpper(_ l: [[Double]], _ b: [Double]) -> [Double] { var x=[Double](repeating:0,count:b.count); for i in b.indices.reversed(){x[i]=(b[i]-((i+1)..<b.count).reduce(0){$0+l[$1][i]*x[$1]})/l[i][i]}; return x }
private func femCholeskySolve(_ l: [[Double]], _ b: [Double]) -> [Double] { femSolveUpper(l, femSolveLower(l,b)) }
private func femSymmetrize(_ a: inout [[Double]]) { for i in a.indices { for j in 0..<i { let v=0.5*(a[i][j]+a[j][i]); a[i][j]=v; a[j][i]=v } } }
private func femJacobiEigen(_ input: [[Double]]) throws -> ([Double], [[Double]]) {
    var a=input, vectors=Array(repeating:Array(repeating:0.0,count:input.count),count:input.count)
    for i in vectors.indices { vectors[i][i]=1 }
    for _ in 0..<(100*input.count*input.count) {
        var p=0,q=0,largest=0.0
        for i in a.indices { for j in (i+1)..<a.count where abs(a[i][j]) > largest { largest=abs(a[i][j]);p=i;q=j } }
        if largest < 1e-12 { return (a.indices.map { a[$0][$0] }, vectors) }
        let theta=0.5*atan2(2*a[p][q],a[q][q]-a[p][p]), c=cos(theta), s=sin(theta)
        for k in a.indices where k != p && k != q { let ap=a[k][p],aq=a[k][q];a[k][p]=c*ap-s*aq;a[p][k]=a[k][p];a[k][q]=s*ap+c*aq;a[q][k]=a[k][q] }
        let app=a[p][p],aqq=a[q][q],apq=a[p][q];a[p][p]=c*c*app-2*s*c*apq+s*s*aqq;a[q][q]=s*s*app+2*s*c*apq+c*c*aqq;a[p][q]=0;a[q][p]=0
        for i in vectors.indices { let vp=vectors[i][p],vq=vectors[i][q];vectors[i][p]=c*vp-s*vq;vectors[i][q]=s*vp+c*vq }
    }
    throw femDynamicsInvalid("modal eigensolver did not converge")
}
private func femDynamicState(time:Double,u:[Double],v:[Double],a:[Double],free:[Int],count:Int,m:[[Double]],k:[[Double]]) -> FEMDynamicState {
    var displacement=[Double](repeating:0,count:count),velocity=displacement,acceleration=displacement
    for (i,dof) in free.enumerated(){displacement[dof]=u[i];velocity[dof]=v[i];acceleration[dof]=a[i]}
    return .init(time:time,displacement:displacement,velocity:velocity,acceleration:acceleration,
                 kineticEnergy:0.5*zip(v,femDenseProduct(m,v)).reduce(0){$0+$1.0*$1.1},
                 strainEnergy:0.5*zip(u,femDenseProduct(k,u)).reduce(0){$0+$1.0*$1.1})
}
private func femDynamicsInvalid(_ message:String) -> NonlinearOptimizationError { .invalidConfiguration(message) }
