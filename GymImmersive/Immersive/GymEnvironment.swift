import CoreGraphics
import RealityKit
import UIKit

/// Procedurally built gym: rubber floor, walls, a mirror wall, dumbbell rack, benches and warm
/// ceiling lights. Everything is static, so nothing moves the participant's frame of reference.
/// The participant stands (or sits) at the origin facing −z.
@MainActor
enum GymEnvironment {
    static func make() async -> Entity {
        let root = Entity()
        root.name = "Gym"

        let rubber = material(0.11, 0.11, 0.12, roughness: 0.95)
        let rubberLight = material(0.16, 0.16, 0.17, roughness: 0.95)
        let wall = material(0.78, 0.74, 0.68, roughness: 0.85)
        let accent = material(0.85, 0.36, 0.12, roughness: 0.6)
        let steel = material(0.55, 0.56, 0.58, roughness: 0.3, metallic: 1)
        let darkSteel = material(0.18, 0.18, 0.2, roughness: 0.4, metallic: 1)
        let leather = material(0.08, 0.08, 0.09, roughness: 0.6)
        let wood = material(0.55, 0.38, 0.22, roughness: 0.7)

        // Floor: 14 m × 14 m of rubber tiles in a subtle checkerboard.
        let tile: Float = 1
        let tileMesh = MeshResource.generateBox(width: tile - 0.01, height: 0.02, depth: tile - 0.01)
        let floor = Entity()
        for x in -7..<7 {
            for z in -7..<7 {
                let e = ModelEntity(mesh: tileMesh, materials: [(x + z).isMultiple(of: 2) ? rubber : rubberLight])
                e.position = [Float(x) + 0.5, -0.01, Float(z) + 0.5]
                floor.addChild(e)
            }
        }
        root.addChild(floor)

        // Walls (room is 14 × 14 × 4.5 m).
        let height: Float = 4.5
        let half: Float = 7
        root.addChild(box(14, height, 0.2, wall, at: [0, height / 2, -half]))
        root.addChild(box(14, height, 0.2, wall, at: [0, height / 2, half]))
        root.addChild(box(0.2, height, 14, wall, at: [-half, height / 2, 0]))
        root.addChild(box(0.2, height, 14, wall, at: [half, height / 2, 0]))
        root.addChild(box(14, 0.2, 14, material(0.2, 0.2, 0.22, roughness: 0.9), at: [0, height, 0]))
        // Orange accent stripe.
        root.addChild(box(13.9, 0.25, 0.05, accent, at: [0, 1.2, -half + 0.12]))
        root.addChild(box(0.05, 0.25, 13.9, accent, at: [-half + 0.12, 1.2, 0]))

        // Mirror wall on the right: polished metal reflects the warm environment lighting.
        let mirror = PhysicallyBasedMaterial.mirror
        root.addChild(box(0.03, 2.4, 9, mirror, at: [half - 0.14, 1.5, -0.5]))
        root.addChild(box(0.05, 0.06, 9.1, darkSteel, at: [half - 0.12, 2.73, -0.5]))
        root.addChild(box(0.05, 0.06, 9.1, darkSteel, at: [half - 0.12, 0.27, -0.5]))

        // Dumbbell rack along the front wall, ~4.5 m away.
        let rack = Entity()
        rack.position = [0, 0, -5.6]
        for tier in 0..<2 {
            let y: Float = 0.45 + Float(tier) * 0.4
            rack.addChild(box(4.2, 0.04, 0.45, darkSteel, at: [0, y, Float(tier) * 0.12]))
            for i in 0..<10 {
                let weight = 2 + (tier * 10 + i) * 2
                let db = DumbbellEntity.makeModel(scale: 0.55 + Float(weight) / 80, label: nil)
                db.position = [-1.9 + Float(i) * 0.42, y + 0.08, Float(tier) * 0.12]
                db.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
                rack.addChild(db)
            }
        }
        for x: Float in [-2.05, 2.05] {
            rack.addChild(box(0.06, 1.0, 0.06, darkSteel, at: [x, 0.5, 0]))
            rack.addChild(box(0.06, 1.0, 0.06, darkSteel, at: [x, 0.5, 0.25]))
        }
        root.addChild(rack)

        // Benches.
        for (x, z, angle) in [(-3.0, -2.5, Float.pi / 2), (3.2, -3.4, Float.pi / 2), (-3.5, 2.5, 0)] as [(Float, Float, Float)] {
            let bench = Entity()
            bench.addChild(box(0.32, 0.08, 1.2, leather, at: [0, 0.45, 0]))
            bench.addChild(box(0.08, 0.41, 0.08, steel, at: [0, 0.205, -0.45]))
            bench.addChild(box(0.08, 0.41, 0.08, steel, at: [0, 0.205, 0.45]))
            bench.addChild(box(0.4, 0.04, 0.08, steel, at: [0, 0.02, -0.45]))
            bench.addChild(box(0.4, 0.04, 0.08, steel, at: [0, 0.02, 0.45]))
            bench.position = [x, 0, z]
            bench.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
            root.addChild(bench)
        }

        // Plate tree and a wooden plyo box for visual variety.
        let tree = Entity()
        tree.addChild(box(0.06, 1.1, 0.06, darkSteel, at: [0, 0.55, 0]))
        for (i, r) in [Float(0.22), 0.18, 0.15].enumerated() {
            let plate = ModelEntity(mesh: .generateCylinder(height: 0.04, radius: r), materials: [rubber])
            plate.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            plate.position = [0, 0.35 + Float(i) * 0.28, 0.06]
            tree.addChild(plate)
        }
        tree.position = [-5.5, 0, -4.8]
        root.addChild(tree)
        root.addChild(box(0.6, 0.5, 0.75, wood, at: [5.0, 0.25, -4.5]))

        // Ceiling light panels (emissive) plus real lights for shading.
        let lightPanel = UnlitMaterial(color: UIColor(red: 1, green: 0.93, blue: 0.82, alpha: 1))
        for x: Float in [-3.5, 0, 3.5] {
            for z: Float in [-4, 0, 4] {
                root.addChild(box(1.4, 0.04, 0.4, lightPanel, at: [x, height - 0.12, z]))
                let light = Entity()
                var point = PointLightComponent(color: UIColor(red: 1, green: 0.88, blue: 0.72, alpha: 1),
                                                intensity: 9000, attenuationRadius: 9)
                point.attenuationFalloffExponent = 1.5
                light.components.set(point)
                light.position = [x, height - 0.4, z]
                root.addChild(light)
            }
        }

        await applyWarmLighting(to: root)
        return root
    }

    private static func material(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, roughness: Float,
                                 metallic: Float = 0) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(red: r, green: g, blue: b, alpha: 1))
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = .init(floatLiteral: metallic)
        return m
    }

    static func box(_ w: Float, _ h: Float, _ d: Float, _ material: some RealityKit.Material,
                    at position: SIMD3<Float>) -> ModelEntity {
        let e = ModelEntity(mesh: .generateBox(width: w, height: h, depth: d), materials: [material])
        e.position = position
        return e
    }

    /// Image-based light from a procedurally drawn warm gradient, so metal and the mirror pick up
    /// a believable indoor tone without any downloaded assets.
    private static func applyWarmLighting(to root: Entity) async {
        guard let image = warmEnvironmentImage(),
              let environment = try? await EnvironmentResource(equirectangular: image, withName: "gymLight") else { return }
        root.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.4))
        root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: root))
        for child in root.descendants() {
            child.components.set(ImageBasedLightReceiverComponent(imageBasedLight: root))
        }
    }

    private static func warmEnvironmentImage() -> CGImage? {
        let width = 256, height = 128
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height),
                                               format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let image = renderer.image { ctx in
            let colors = [UIColor(red: 1.0, green: 0.92, blue: 0.80, alpha: 1).cgColor,
                          UIColor(red: 0.62, green: 0.52, blue: 0.42, alpha: 1).cgColor,
                          UIColor(red: 0.12, green: 0.11, blue: 0.11, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                      locations: [0, 0.5, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
            UIColor(red: 1, green: 0.97, blue: 0.9, alpha: 1).setFill()
            for i in 0..<6 { ctx.fill(CGRect(x: 10 + i * 42, y: 6, width: 24, height: 6)) }
        }
        return image.cgImage
    }
}

private extension Entity {
    func descendants() -> [Entity] {
        children.flatMap { [$0] + $0.descendants() }
    }
}

extension PhysicallyBasedMaterial {
    static var mirror: PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(white: 0.95, alpha: 1))
        m.metallic = .init(floatLiteral: 1)
        m.roughness = .init(floatLiteral: 0.04)
        return m
    }
}
