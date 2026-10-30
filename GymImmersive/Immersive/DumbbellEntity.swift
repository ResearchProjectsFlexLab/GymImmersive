import RealityKit
import UIKit

/// The participant's virtual dumbbell: a knurled handle, two plates sized by the virtual weight
/// and labelled with it, and plate colours driven by the 2-back task.
///
/// The handle runs along the local x axis and its centre sits at the local origin.
@MainActor
final class DumbbellEntity {
    let root = Entity()
    private let platesRoot = Entity()
    private var plates: [ModelEntity] = []
    private var currentWeight: Double = -1
    private var currentColor: PlateColor?? = .none

    /// Pose of the dumbbell relative to a RealityKit palm anchor. Kept in one place so it can be
    /// tuned on device (the palm anchor's axes cannot be verified in the Simulator).
    static let palmOffset = SIMD3<Float>(0, -0.03, 0)
    static let palmRotation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])

    init() {
        root.name = "Dumbbell"
        root.addChild(Self.handle())
        root.addChild(platesRoot)
        setWeight(2)
        setPlateColor(nil)
    }

    func setWeight(_ kg: Double) {
        guard kg != currentWeight else { return }
        currentWeight = kg
        platesRoot.children.removeAll()
        plates = []
        let radius = Float(0.065 + kg * 0.0035)
        let thickness = Float(0.022 + kg * 0.0014)
        let label = "\(Int(kg.rounded())) kg"
        for side: Float in [-1, 1] {
            let plate = ModelEntity(mesh: .generateCylinder(height: thickness, radius: radius),
                                    materials: [Self.plateMaterial(nil)])
            plate.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            plate.position = [side * (0.075 + thickness / 2), 0, 0]
            platesRoot.addChild(plate)
            plates.append(plate)

            let text = ModelEntity(mesh: .generateText(label, extrusionDepth: 0.002,
                                                       font: .systemFont(ofSize: 0.022, weight: .heavy),
                                                       containerFrame: .zero, alignment: .center, lineBreakMode: .byClipping),
                                   materials: [UnlitMaterial(color: .white)])
            let bounds = text.visualBounds(relativeTo: nil)
            // Face outward from each plate, centred on it.
            text.orientation = simd_quatf(angle: side * .pi / 2, axis: [0, 1, 0])
            let offset = side * (0.075 + thickness + 0.002)
            text.position = [offset, -bounds.extents.y / 2 - bounds.min.y, side * (bounds.extents.x / 2 + bounds.min.x)]
            platesRoot.addChild(text)
        }
        if let color = currentColor { applyColor(color) }
    }

    func setPlateColor(_ color: PlateColor?) {
        guard currentColor != .some(color) else { return }
        currentColor = .some(color)
        applyColor(color)
    }

    private func applyColor(_ color: PlateColor?) {
        let material = Self.plateMaterial(color)
        for plate in plates { plate.model?.materials = [material] }
    }

    private static func plateMaterial(_ color: PlateColor?) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        if let rgb = color?.rgb {
            m.baseColor = .init(tint: UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1))
            m.roughness = 0.45
        } else {
            m.baseColor = .init(tint: UIColor(white: 0.08, alpha: 1))
            m.roughness = 0.9
        }
        return m
    }

    private static func handle() -> Entity {
        var chrome = PhysicallyBasedMaterial()
        chrome.baseColor = .init(tint: UIColor(white: 0.8, alpha: 1))
        chrome.metallic = 1.0
        chrome.roughness = 0.25
        let e = Entity()
        let bar = ModelEntity(mesh: .generateCylinder(height: 0.30, radius: 0.016), materials: [chrome])
        bar.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        e.addChild(bar)
        for side: Float in [-1, 1] {
            let collar = ModelEntity(mesh: .generateCylinder(height: 0.018, radius: 0.027), materials: [chrome])
            collar.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            collar.position = [side * 0.066, 0, 0]
            e.addChild(collar)
        }
        return e
    }

    /// Simple static dumbbell for the rack.
    static func makeModel(scale: Float, label: String?) -> Entity {
        var iron = PhysicallyBasedMaterial()
        iron.baseColor = .init(tint: UIColor(white: 0.12, alpha: 1))
        iron.roughness = 0.6
        iron.metallic = .init(floatLiteral: 0.6)
        let e = Entity()
        let bar = ModelEntity(mesh: .generateCylinder(height: 0.26, radius: 0.014),
                              materials: [PhysicallyBasedMaterial.mirror])
        bar.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        e.addChild(bar)
        for side: Float in [-1, 1] {
            let head = ModelEntity(mesh: .generateCylinder(height: 0.05, radius: 0.06), materials: [iron])
            head.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
            head.position = [side * 0.1, 0, 0]
            e.addChild(head)
        }
        e.scale = SIMD3(repeating: scale)
        return e
    }
}
