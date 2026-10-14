import Foundation
import NumericCore
import NumericCoreSparse

public struct FEMNode2D: Sendable, Hashable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct FEMConstraint: Sendable, Hashable {
    public let dof: Int
    public let value: Double
    public init(dof: Int, value: Double) { self.dof = dof; self.value = value }
}

public struct FEMNodalLoad: Sendable, Hashable {
    public let dof: Int
    public let value: Double
    public init(dof: Int, value: Double) { self.dof = dof; self.value = value }
}

public struct ThermalMaterial: Sendable, Hashable {
    public let conductivity: Double
    public let thickness: Double
    public init(conductivity: Double, thickness: Double = 1) {
        self.conductivity = conductivity; self.thickness = thickness
    }
}

public struct ThermalTriangle3: Sendable, Hashable {
    public let nodes: [Int]
    public let material: Int
    public let heatSource: Double
    public init(nodes: [Int], material: Int, heatSource: Double = 0) {
        self.nodes = nodes; self.material = material; self.heatSource = heatSource
    }
}

public struct ThermalFEMModel: Sendable, Hashable {
    public let nodes: [FEMNode2D]
    public let materials: [ThermalMaterial]
    public let elements: [ThermalTriangle3]
    public let constraints: [FEMConstraint]
    public let loads: [FEMNodalLoad]

    public init(nodes: [FEMNode2D], materials: [ThermalMaterial],
                elements: [ThermalTriangle3], constraints: [FEMConstraint],
                loads: [FEMNodalLoad] = []) {
        self.nodes = nodes; self.materials = materials; self.elements = elements
        self.constraints = constraints; self.loads = loads
    }

    public func solve() throws -> FEMStaticResult {
        try validate()
        var entries: [SparseEntry<Double>] = [], rhs = [Double](repeating: 0, count: nodes.count)
        try femAddLoads(&rhs, loads)
        for element in elements {
            let geometry = try femTriangleGeometry(element.nodes.map { nodes[$0] })
            let material = materials[element.material]
            let factor = material.conductivity * material.thickness / (4 * geometry.area)
            for localRow in 0..<3 {
                rhs[element.nodes[localRow]] += element.heatSource * material.thickness * geometry.area / 3
                for localColumn in 0..<3 {
                    entries.append(.init(row: element.nodes[localRow], column: element.nodes[localColumn],
                        value: factor * (geometry.b[localRow] * geometry.b[localColumn]
                                       + geometry.c[localRow] * geometry.c[localColumn])))
                }
            }
        }
        return try femSolveConstrained(try SparseMatrix(rows: nodes.count, cols: nodes.count,
                                                        entries: entries), rhs, constraints)
    }

    private func validate() throws {
        try femValidateCommon(dofs: nodes.count, constraints: constraints, loads: loads)
        guard nodes.count >= 3, !materials.isEmpty, !elements.isEmpty,
              nodes.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              materials.allSatisfy({ $0.conductivity.isFinite && $0.conductivity > 0 && $0.thickness.isFinite && $0.thickness > 0 }),
              elements.allSatisfy({ $0.nodes.count == 3 && materials.indices.contains($0.material) && $0.nodes.allSatisfy(nodes.indices.contains) && $0.heatSource.isFinite })
        else { throw femInvalid("invalid thermal FEM model") }
        var used = Set<[Int]>()
        for element in elements {
            guard Set(element.nodes).count == 3, used.insert(element.nodes.sorted()).inserted else {
                throw femInvalid("thermal elements must be distinct non-repeated triangles")
            }
            _ = try femTriangleGeometry(element.nodes.map { nodes[$0] })
        }
    }
}

public struct TrussMaterial: Sendable, Hashable {
    public let youngModulus: Double
    public let area: Double
    /// Mass density per unit volume. Static analysis permits zero; dynamics requires positive density.
    public let density: Double
    public init(youngModulus: Double, area: Double, density: Double = 0) {
        self.youngModulus = youngModulus; self.area = area; self.density = density
    }
}

public struct TrussElement2D: Sendable, Hashable {
    public let nodes: [Int]
    public let material: Int
    public init(nodes: [Int], material: Int) { self.nodes = nodes; self.material = material }
}

public struct TrussElementResult: Sendable, Hashable {
    public let strain: Double
    public let stress: Double
    public let axialForce: Double
}

public struct TrussFEMModel: Sendable, Hashable {
    public let nodes: [FEMNode2D]
    public let materials: [TrussMaterial]
    public let elements: [TrussElement2D]
    public let constraints: [FEMConstraint]
    public let loads: [FEMNodalLoad]

    public init(nodes: [FEMNode2D], materials: [TrussMaterial],
                elements: [TrussElement2D], constraints: [FEMConstraint],
                loads: [FEMNodalLoad] = []) {
        self.nodes = nodes; self.materials = materials; self.elements = elements
        self.constraints = constraints; self.loads = loads
    }

    public func solve() throws -> TrussStaticResult {
        try validate()
        let count = 2 * nodes.count
        var entries: [SparseEntry<Double>] = [], rhs = [Double](repeating: 0, count: count)
        try femAddLoads(&rhs, loads)
        for element in elements {
            let geometry = try femTrussGeometry(nodes[element.nodes[0]], nodes[element.nodes[1]])
            let material = materials[element.material]
            let direction = [-geometry.cosine, -geometry.sine, geometry.cosine, geometry.sine]
            let dofs = [2*element.nodes[0], 2*element.nodes[0]+1, 2*element.nodes[1], 2*element.nodes[1]+1]
            let factor = material.youngModulus * material.area / geometry.length
            for row in 0..<4 { for column in 0..<4 {
                entries.append(.init(row: dofs[row], column: dofs[column],
                                     value: factor * direction[row] * direction[column]))
            }}
        }
        let staticResult = try femSolveConstrained(
            try SparseMatrix(rows: count, cols: count, entries: entries), rhs, constraints)
        let elementResults = try elements.map { element -> TrussElementResult in
            let geometry = try femTrussGeometry(nodes[element.nodes[0]], nodes[element.nodes[1]])
            let dofs = [2*element.nodes[0], 2*element.nodes[0]+1, 2*element.nodes[1], 2*element.nodes[1]+1]
            let direction = [-geometry.cosine, -geometry.sine, geometry.cosine, geometry.sine]
            let elongation = zip(direction, dofs).reduce(0) { $0 + $1.0 * staticResult.values[$1.1] }
            let strain = elongation / geometry.length, material = materials[element.material]
            let stress = material.youngModulus * strain
            return .init(strain: strain, stress: stress, axialForce: material.area * stress)
        }
        return .init(staticResult: staticResult, elements: elementResults)
    }

    func validate() throws {
        try femValidateCommon(dofs: 2*nodes.count, constraints: constraints, loads: loads)
        guard nodes.count >= 2, !materials.isEmpty, !elements.isEmpty,
              nodes.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              materials.allSatisfy({ $0.youngModulus.isFinite && $0.youngModulus > 0 && $0.area.isFinite && $0.area > 0 && $0.density.isFinite && $0.density >= 0 }),
              elements.allSatisfy({ $0.nodes.count == 2 && materials.indices.contains($0.material) && $0.nodes.allSatisfy(nodes.indices.contains) && $0.nodes[0] != $0.nodes[1] })
        else { throw femInvalid("invalid truss FEM model") }
        var used = Set<[Int]>()
        for element in elements {
            let key = element.nodes.sorted()
            guard used.insert(key).inserted else { throw femInvalid("duplicate truss element") }
            _ = try femTrussGeometry(nodes[element.nodes[0]], nodes[element.nodes[1]])
        }
    }
}

public struct FEMStaticResult {
    public let values: [Double]
    public let reactions: [Double]
    public let strainEnergy: Double
    public let maximumFreeResidual: Double
    public let reducedRelativeResidual: Double
    public let stiffness: SparseMatrix<Double>
}

public struct TrussStaticResult {
    public let staticResult: FEMStaticResult
    public let elements: [TrussElementResult]
}

private func femSolveConstrained(_ stiffness: SparseMatrix<Double>, _ rhs: [Double],
                                 _ constraints: [FEMConstraint]) throws -> FEMStaticResult {
    let prescribed = Dictionary(uniqueKeysWithValues: constraints.map { ($0.dof, $0.value) })
    let free = rhs.indices.filter { prescribed[$0] == nil }
    guard !free.isEmpty else { throw femInvalid("FEM model has no free degrees of freedom") }
    let freeMap = Dictionary(uniqueKeysWithValues: free.enumerated().map { ($0.element, $0.offset) })
    var entries: [SparseEntry<Double>] = [], reducedRHS = free.map { rhs[$0] }
    for row in 0..<stiffness.rows { for index in stiffness.csrRowPointers[row]..<stiffness.csrRowPointers[row+1] {
        let column = stiffness.csrColumnIndices[index], value = stiffness.csrValues[index]
        if let reducedRow = freeMap[row] {
            if let reducedColumn = freeMap[column] {
                entries.append(.init(row: reducedRow, column: reducedColumn, value: value))
            } else if let fixed = prescribed[column] { reducedRHS[reducedRow] -= value * fixed }
        }
    }}
    let reduced = try SparseMatrix(rows: free.count, cols: free.count, entries: entries)
    let report = try NumericCoreSparse.SparseLinearSolver.solveCholesky(matrix: reduced, rhs: reducedRHS)
    var values = [Double](repeating: 0, count: rhs.count)
    for (dof, value) in prescribed { values[dof] = value }
    for (index, dof) in free.enumerated() { values[dof] = report.solution[index] }
    var product = [Double](repeating: 0, count: rhs.count)
    for row in 0..<stiffness.rows {
        for index in stiffness.csrRowPointers[row]..<stiffness.csrRowPointers[row+1] {
            product[row] += stiffness.csrValues[index] * values[stiffness.csrColumnIndices[index]]
        }
    }
    let residual = zip(product, rhs).map(-)
    let maximumFreeResidual = free.map { abs(residual[$0]) }.max() ?? 0
    let reactions = residual.indices.map { prescribed[$0] == nil ? 0 : residual[$0] }
    var energy = 0.0
    for index in values.indices { energy += 0.5 * values[index] * product[index] }
    return .init(values: values, reactions: reactions, strainEnergy: energy,
                 maximumFreeResidual: maximumFreeResidual,
                 reducedRelativeResidual: report.relativeResidual, stiffness: stiffness)
}

private func femValidateCommon(dofs: Int, constraints: [FEMConstraint],
                               loads: [FEMNodalLoad]) throws {
    guard !constraints.isEmpty, Set(constraints.map(\.dof)).count == constraints.count,
          constraints.allSatisfy({ (0..<dofs).contains($0.dof) && $0.value.isFinite }),
          loads.allSatisfy({ (0..<dofs).contains($0.dof) && $0.value.isFinite })
    else { throw femInvalid("invalid FEM boundary conditions or loads") }
}

private func femAddLoads(_ rhs: inout [Double], _ loads: [FEMNodalLoad]) throws {
    for load in loads { rhs[load.dof] += load.value }
    guard rhs.allSatisfy(\.isFinite) else { throw femInvalid("non-finite assembled FEM load") }
}

private func femTriangleGeometry(_ nodes: [FEMNode2D]) throws
    -> (area: Double, b: [Double], c: [Double]) {
    let twiceArea = (nodes[1].x-nodes[0].x)*(nodes[2].y-nodes[0].y)
        - (nodes[2].x-nodes[0].x)*(nodes[1].y-nodes[0].y)
    let area = 0.5 * abs(twiceArea)
    guard area.isFinite, area > 1e-14 else { throw femInvalid("degenerate thermal triangle") }
    return (area, [nodes[1].y-nodes[2].y, nodes[2].y-nodes[0].y, nodes[0].y-nodes[1].y],
            [nodes[2].x-nodes[1].x, nodes[0].x-nodes[2].x, nodes[1].x-nodes[0].x])
}

func femTrussGeometry(_ first: FEMNode2D, _ second: FEMNode2D) throws
    -> (length: Double, cosine: Double, sine: Double) {
    let dx = second.x-first.x, dy = second.y-first.y, length = hypot(dx, dy)
    guard length.isFinite, length > 1e-14 else { throw femInvalid("zero-length truss element") }
    return (length, dx/length, dy/length)
}

private func femInvalid(_ message: String) -> NonlinearOptimizationError {
    .invalidConfiguration(message)
}
