import Foundation
import NumericCoreSparse

public enum ContinuumKinematics: Sendable, Hashable {
    case planeStress
    case planeStrain
}

public struct LinearElasticContinuumMaterial: Sendable, Hashable {
    public let youngModulus: Double
    public let poissonRatio: Double
    public let thickness: Double
    public let kinematics: ContinuumKinematics

    public init(youngModulus: Double, poissonRatio: Double, thickness: Double = 1,
                kinematics: ContinuumKinematics = .planeStress) {
        self.youngModulus = youngModulus
        self.poissonRatio = poissonRatio
        self.thickness = thickness
        self.kinematics = kinematics
    }
}

public struct ContinuumTriangle3: Sendable, Hashable {
    public let nodes: [Int]
    public let material: Int
    public let bodyForceX: Double
    public let bodyForceY: Double

    public init(nodes: [Int], material: Int, bodyForceX: Double = 0,
                bodyForceY: Double = 0) {
        self.nodes = nodes; self.material = material
        self.bodyForceX = bodyForceX; self.bodyForceY = bodyForceY
    }
}

public struct ContinuumElementResult: Sendable, Hashable {
    /// `[epsilon_xx, epsilon_yy, gamma_xy]`.
    public let strain: [Double]
    /// `[sigma_xx, sigma_yy, tau_xy, sigma_zz]`.
    public let stress: [Double]
    public let vonMisesStress: Double
    public let principalStressMaximum: Double
    public let principalStressMinimum: Double
    public let strainEnergy: Double
    public let area: Double
}

public struct ContinuumStaticResult {
    public let staticResult: FEMStaticResult
    public let elements: [ContinuumElementResult]
    public let maximumElementEnergyMismatch: Double
}

public struct ContinuumFEMModel: Sendable, Hashable {
    public let nodes: [FEMNode2D]
    public let materials: [LinearElasticContinuumMaterial]
    public let elements: [ContinuumTriangle3]
    public let constraints: [FEMConstraint]
    public let loads: [FEMNodalLoad]

    public init(nodes: [FEMNode2D], materials: [LinearElasticContinuumMaterial],
                elements: [ContinuumTriangle3], constraints: [FEMConstraint],
                loads: [FEMNodalLoad] = []) {
        self.nodes = nodes; self.materials = materials; self.elements = elements
        self.constraints = constraints; self.loads = loads
    }

    public func solve() throws -> ContinuumStaticResult {
        try validate()
        let count = 2 * nodes.count
        var entries: [SparseEntry<Double>] = []
        var rightHandSide = [Double](repeating: 0, count: count)
        try femAddLoads(&rightHandSide, loads)
        for element in elements {
            let data = try elementData(element)
            let dofs = continuumDOFs(element.nodes)
            for localNode in 0..<3 {
                rightHandSide[dofs[2*localNode]] += element.bodyForceX * data.material.thickness * data.area / 3
                rightHandSide[dofs[2*localNode+1]] += element.bodyForceY * data.material.thickness * data.area / 3
            }
            let factor = data.material.thickness * data.area
            let db = continuumMultiply(data.constitutive, data.strainDisplacement)
            for row in 0..<6 { for column in 0..<6 {
                let value = (0..<3).reduce(0.0) {
                    $0 + data.strainDisplacement[$1][row] * db[$1][column]
                }
                entries.append(.init(row: dofs[row], column: dofs[column], value: factor * value))
            }}
        }
        let staticResult = try femSolveConstrained(
            try SparseMatrix(rows: count, cols: count, entries: entries),
            rightHandSide, constraints)
        var recoveredEnergy = 0.0
        let recovered = try elements.map { element -> ContinuumElementResult in
            let data = try elementData(element), dofs = continuumDOFs(element.nodes)
            let displacement = dofs.map { staticResult.values[$0] }
            let strain = continuumMultiply(data.strainDisplacement, displacement)
            let inPlane = continuumMultiply(data.constitutive, strain)
            let sigmaZZ: Double
            switch data.material.kinematics {
            case .planeStress: sigmaZZ = 0
            case .planeStrain:
                sigmaZZ = data.material.youngModulus * data.material.poissonRatio
                    / ((1 + data.material.poissonRatio) * (1 - 2*data.material.poissonRatio))
                    * (strain[0] + strain[1])
            }
            let mean = 0.5 * (inPlane[0] + inPlane[1])
            let radius = hypot(0.5 * (inPlane[0] - inPlane[1]), inPlane[2])
            let vonMises = sqrt(0.5 * (pow(inPlane[0]-inPlane[1],2)
                + pow(inPlane[1]-sigmaZZ,2) + pow(sigmaZZ-inPlane[0],2))
                + 3*pow(inPlane[2],2))
            let energy = 0.5 * data.material.thickness * data.area
                * zip(strain, inPlane).reduce(0) { $0 + $1.0*$1.1 }
            recoveredEnergy += energy
            return .init(strain: strain, stress: inPlane + [sigmaZZ],
                vonMisesStress: vonMises, principalStressMaximum: mean + radius,
                principalStressMinimum: mean - radius, strainEnergy: energy, area: data.area)
        }
        return .init(staticResult: staticResult, elements: recovered,
            maximumElementEnergyMismatch: abs(recoveredEnergy - staticResult.strainEnergy))
    }

    private func validate() throws {
        try femValidateCommon(dofs: 2*nodes.count, constraints: constraints, loads: loads)
        guard nodes.count >= 3, !materials.isEmpty, !elements.isEmpty,
              nodes.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              materials.allSatisfy({ material in
                  material.youngModulus.isFinite && material.youngModulus > 0
                    && material.poissonRatio.isFinite && material.poissonRatio > -1
                    && material.poissonRatio < 0.5 && material.thickness.isFinite
                    && material.thickness > 0
              }),
              elements.allSatisfy({ $0.nodes.count == 3 && materials.indices.contains($0.material)
                  && $0.nodes.allSatisfy(nodes.indices.contains) && $0.bodyForceX.isFinite
                  && $0.bodyForceY.isFinite })
        else { throw femInvalid("invalid continuum FEM model") }
        var used = Set<[Int]>()
        for element in elements {
            guard Set(element.nodes).count == 3,
                  used.insert(element.nodes.sorted()).inserted else {
                throw femInvalid("continuum elements must be distinct non-repeated triangles")
            }
            _ = try femTriangleGeometry(element.nodes.map { nodes[$0] })
        }
    }

    private func elementData(_ element: ContinuumTriangle3) throws
        -> (area: Double, material: LinearElasticContinuumMaterial,
            strainDisplacement: [[Double]], constitutive: [[Double]]) {
        let coordinates = element.nodes.map { nodes[$0] }
        let geometry = try femTriangleGeometry(coordinates)
        let signedTwiceArea = (coordinates[1].x-coordinates[0].x)*(coordinates[2].y-coordinates[0].y)
            - (coordinates[2].x-coordinates[0].x)*(coordinates[1].y-coordinates[0].y)
        let scale = 1 / signedTwiceArea
        var b = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 3)
        for node in 0..<3 {
            b[0][2*node] = geometry.b[node] * scale
            b[1][2*node+1] = geometry.c[node] * scale
            b[2][2*node] = geometry.c[node] * scale
            b[2][2*node+1] = geometry.b[node] * scale
        }
        let material = materials[element.material]
        return (geometry.area, material, b, continuumConstitutive(material))
    }
}

private func continuumDOFs(_ nodes: [Int]) -> [Int] {
    nodes.flatMap { [2*$0, 2*$0+1] }
}
private func continuumConstitutive(_ material: LinearElasticContinuumMaterial) -> [[Double]] {
    let e = material.youngModulus, nu = material.poissonRatio
    switch material.kinematics {
    case .planeStress:
        let factor = e / (1-nu*nu)
        return [[factor, factor*nu, 0], [factor*nu, factor, 0],
                [0, 0, factor*(1-nu)/2]]
    case .planeStrain:
        let factor = e / ((1+nu)*(1-2*nu))
        return [[factor*(1-nu), factor*nu, 0], [factor*nu, factor*(1-nu), 0],
                [0, 0, factor*(1-2*nu)/2]]
    }
}
private func continuumMultiply(_ matrix: [[Double]], _ vector: [Double]) -> [Double] {
    matrix.map { row in zip(row, vector).reduce(0) { $0 + $1.0*$1.1 } }
}
private func continuumMultiply(_ first: [[Double]], _ second: [[Double]]) -> [[Double]] {
    first.map { row in (0..<second[0].count).map { column in
        row.indices.reduce(0) { $0 + row[$1]*second[$1][column] }
    }}
}
