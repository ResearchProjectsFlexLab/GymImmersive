import CoreGraphics
import RealityKit
import UIKit

/// Procedurally built gym: rubber floor with a wooden lifting platform and a turf lane, daylight
/// windows, a mirror wall, a dark feature wall with signage behind the dumbbell rack, a power rack,
/// kettlebells, medicine balls, plyo boxes, benches, plants, ceiling beams and warm lighting with
/// real shadows. Everything is static, so nothing moves the participant's frame of reference.
/// The participant stands (or sits) at the origin facing −z.
@MainActor
enum GymEnvironment {
    static let height: Float = 4.5
    static let half: Float = 7

    static func make() async -> Entity {
        let root = Entity()
        root.name = "Gym"
        let props = Entity()  // equipment that casts grounding shadows
        root.addChild(props)

        buildRoom(in: root)
        buildFloorFeatures(in: root)
        buildDumbbellRack(in: props)
        buildPowerRack(in: props)
        buildSmallEquipment(in: props)
        buildPlants(in: props)
        buildLights(in: root)

        for entity in props.descendants() where entity is ModelEntity {
            entity.components.set(GroundingShadowComponent(castsShadow: true))
        }
        await applyWarmLighting(to: root)
        return root
    }

    // MARK: Room

    private static func buildRoom(in root: Entity) {
        let rubber = material(0.2, 0.2, 0.21, roughness: 0.95)
        let rubberLight = material(0.25, 0.25, 0.26, roughness: 0.95)
        let wall = material(0.82, 0.80, 0.76, roughness: 0.85)
        let feature = material(0.2, 0.21, 0.23, roughness: 0.7)
        let accent = material(0.95, 0.38, 0.10, roughness: 0.5)
        let ceiling = material(0.42, 0.42, 0.44, roughness: 0.9)
        let darkSteel = material(0.18, 0.18, 0.2, roughness: 0.4, metallic: 1)

        // Floor: 14 m × 14 m of rubber tiles in a subtle checkerboard.
        let tileMesh = MeshResource.generateBox(width: 0.99, height: 0.02, depth: 0.99)
        for x in -7..<7 {
            for z in -7..<7 {
                let e = ModelEntity(mesh: tileMesh, materials: [(x + z).isMultiple(of: 2) ? rubber : rubberLight])
                e.position = [Float(x) + 0.5, -0.01, Float(z) + 0.5]
                root.addChild(e)
            }
        }

        // Walls (room is 14 × 14 × 4.5 m) and ceiling.
        root.addChild(box(14, height, 0.2, wall, at: [0, height / 2, half]))
        root.addChild(box(0.2, height, 14, wall, at: [-half, height / 2, 0]))
        root.addChild(box(0.2, height, 14, wall, at: [half, height / 2, 0]))
        root.addChild(box(14, 0.2, 14, ceiling, at: [0, height, 0]))

        // Front wall: dark feature wall with an orange stripe and signage, behind the rack.
        root.addChild(box(14, height, 0.2, feature, at: [0, height / 2, -half]))
        root.addChild(box(13.9, 0.18, 0.04, accent, at: [0, 1.35, -half + 0.12]))
        if let sign = text("TRAIN HARD · STAY FOCUSED", size: 0.32, color: UIColor(white: 0.92, alpha: 1)) {
            sign.position.y = 3.55
            sign.position.z = -half + 0.12
            root.addChild(sign)
        }
        // Side accent stripes.
        root.addChild(box(0.04, 0.18, 13.9, accent, at: [-half + 0.12, 1.35, 0]))
        root.addChild(box(14, 0.6, 0.05, material(0.25, 0.25, 0.27, roughness: 0.8), at: [0, 0.3, half - 0.12]))

        // Left wall: tall daylight windows with black frames.
        let daylight = UnlitMaterial(color: UIColor(red: 0.86, green: 0.93, blue: 1.0, alpha: 1))
        for z: Float in [-4.2, -1.4, 1.4, 4.2] {
            root.addChild(box(0.03, 2.4, 2.0, daylight, at: [-half + 0.12, 2.3, z]))
            for dz: Float in [-1.02, 0, 1.02] {
                root.addChild(box(0.06, 2.5, 0.06, darkSteel, at: [-half + 0.14, 2.3, z + dz]))
            }
            root.addChild(box(0.06, 0.06, 2.1, darkSteel, at: [-half + 0.14, 3.53, z]))
            root.addChild(box(0.06, 0.06, 2.1, darkSteel, at: [-half + 0.14, 1.07, z]))
            root.addChild(box(0.06, 0.04, 2.1, darkSteel, at: [-half + 0.14, 2.3, z]))
        }

        // Right wall: mirror with a steel frame.
        root.addChild(box(0.03, 2.4, 9, PhysicallyBasedMaterial.mirror, at: [half - 0.14, 1.5, -0.5]))
        root.addChild(box(0.05, 0.06, 9.1, darkSteel, at: [half - 0.12, 2.73, -0.5]))
        root.addChild(box(0.05, 0.06, 9.1, darkSteel, at: [half - 0.12, 0.27, -0.5]))

        // Back wall logo.
        if let logo = text("IMMERSIVE GYM", size: 0.45, color: UIColor(red: 0.95, green: 0.38, blue: 0.10, alpha: 1)) {
            logo.position = [0, 2.6, half - 0.12]
            logo.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
            root.addChild(logo)
        }

        // Exposed ceiling beams and ducts.
        for x: Float in [-4.5, -1.5, 1.5, 4.5] {
            root.addChild(box(0.18, 0.3, 14, darkSteel, at: [x, height - 0.25, 0]))
        }
        // Ducts run along the side walls, out of the participant's line of sight.
        for x: Float in [-6.3, 6.3] {
            let duct = ModelEntity(mesh: .generateCylinder(height: 14, radius: 0.18),
                                   materials: [material(0.6, 0.6, 0.62, roughness: 0.35, metallic: 1)])
            duct.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
            duct.position = [x, height - 0.35, 0]
            root.addChild(duct)
        }
    }

    private static func buildFloorFeatures(in root: Entity) {
        // Wooden lifting platform under the participant, with rubber side panels.
        let wood = material(0.62, 0.44, 0.26, roughness: 0.6)
        let rubber = material(0.08, 0.08, 0.09, roughness: 0.95)
        root.addChild(box(1.2, 0.03, 2.4, wood, at: [0, 0.015, 0]))
        root.addChild(box(0.6, 0.03, 2.4, rubber, at: [-0.9, 0.015, 0]))
        root.addChild(box(0.6, 0.03, 2.4, rubber, at: [0.9, 0.015, 0]))

        // Turf sled lane along the left side with white lines.
        let turf = material(0.12, 0.42, 0.18, roughness: 1)
        let line = UnlitMaterial(color: UIColor(white: 0.9, alpha: 1))
        root.addChild(box(1.8, 0.012, 12, turf, at: [-5.4, 0.006, 0]))
        for z in stride(from: Float(-5), through: 5, by: 2.5) {
            root.addChild(box(1.8, 0.014, 0.05, line, at: [-5.4, 0.007, z]))
        }
    }

    // MARK: Equipment

    private static func buildDumbbellRack(in props: Entity) {
        let darkSteel = material(0.18, 0.18, 0.2, roughness: 0.4, metallic: 1)
        let rack = Entity()
        rack.position = [0, 0, -5.9]
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
        props.addChild(rack)
    }

    private static func buildPowerRack(in props: Entity) {
        let frame = material(0.10, 0.10, 0.11, roughness: 0.45, metallic: 0.8)
        let chrome = PhysicallyBasedMaterial.mirror
        let plateRubber = material(0.06, 0.06, 0.07, roughness: 0.9)
        let accent = material(0.95, 0.38, 0.10, roughness: 0.5)
        let rack = Entity()
        rack.position = [-3.4, 0, -4.2]
        for (x, z) in [(-0.6, -0.6), (0.6, -0.6), (-0.6, 0.6), (0.6, 0.6)] as [(Float, Float)] {
            rack.addChild(box(0.08, 2.3, 0.08, frame, at: [x, 1.15, z]))
        }
        for z: Float in [-0.6, 0.6] { rack.addChild(box(1.28, 0.08, 0.08, frame, at: [0, 2.3, z])) }
        for x: Float in [-0.6, 0.6] { rack.addChild(box(0.08, 0.08, 1.28, frame, at: [x, 2.3, 0])) }
        // Barbell on the hooks with bumper plates.
        let bar = ModelEntity(mesh: .generateCylinder(height: 2.1, radius: 0.016), materials: [chrome])
        bar.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        bar.position = [0, 1.35, -0.62]
        rack.addChild(bar)
        for side: Float in [-1, 1] {
            for (i, color) in [accent, plateRubber].enumerated() {
                let plate = ModelEntity(mesh: .generateCylinder(height: 0.06, radius: 0.225), materials: [color])
                plate.orientation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
                plate.position = [side * (0.78 + Float(i) * 0.065), 1.35, -0.62]
                rack.addChild(plate)
            }
        }
        // Flat bench inside the rack.
        rack.addChild(box(0.3, 0.08, 1.2, material(0.08, 0.08, 0.09, roughness: 0.6), at: [0, 0.45, 0.1]))
        rack.addChild(box(0.06, 0.41, 0.06, frame, at: [0, 0.205, -0.35]))
        rack.addChild(box(0.06, 0.41, 0.06, frame, at: [0, 0.205, 0.55]))
        props.addChild(rack)
    }

    private static func buildSmallEquipment(in props: Entity) {
        let iron = material(0.12, 0.12, 0.13, roughness: 0.6, metallic: 0.6)
        let leather = material(0.08, 0.08, 0.09, roughness: 0.6)
        let steel = material(0.55, 0.56, 0.58, roughness: 0.3, metallic: 1)
        let wood = material(0.62, 0.44, 0.26, roughness: 0.7)

        // Kettlebells along the right wall, coloured by weight.
        let kbColors: [(CGFloat, CGFloat, CGFloat)] = [(0.85, 0.2, 0.2), (0.2, 0.45, 0.9), (0.95, 0.8, 0.15),
                                                        (0.2, 0.65, 0.3), (0.55, 0.3, 0.8), (0.95, 0.45, 0.1)]
        for (i, c) in kbColors.enumerated() {
            let r = 0.09 + Float(i) * 0.01
            let kb = Entity()
            let bell = ModelEntity(mesh: .generateSphere(radius: r), materials: [material(c.0, c.1, c.2, roughness: 0.5)])
            bell.position.y = r
            kb.addChild(bell)
            let handle = ModelEntity(mesh: .generateBox(width: r * 1.2, height: 0.03, depth: 0.03, cornerRadius: 0.012),
                                     materials: [iron])
            handle.position.y = r * 2.1
            kb.addChild(handle)
            kb.position = [5.9, 0, -3.5 + Float(i) * 0.55]
            props.addChild(kb)
        }

        // Medicine balls.
        for (i, z) in [Float(1.2), 1.75, 2.3].enumerated() {
            let ball = ModelEntity(mesh: .generateSphere(radius: 0.17),
                                   materials: [material(0.15 + CGFloat(i) * 0.25, 0.15, 0.18, roughness: 0.9)])
            ball.position = [5.9, 0.17, z]
            props.addChild(ball)
        }

        // Plyo boxes stacked by size.
        props.addChild(box(0.75, 0.6, 0.6, wood, at: [4.6, 0.3, -5.6]))
        props.addChild(box(0.6, 0.45, 0.5, wood, at: [5.5, 0.225, -5.6]))
        props.addChild(box(0.5, 0.3, 0.4, wood, at: [4.6, 0.75, -5.6]))

        // Benches.
        for (x, z, angle) in [(3.2, -3.0, Float.pi / 2), (-3.6, 2.6, 0)] as [(Float, Float, Float)] {
            let bench = Entity()
            bench.addChild(box(0.32, 0.08, 1.2, leather, at: [0, 0.45, 0]))
            bench.addChild(box(0.08, 0.41, 0.08, steel, at: [0, 0.205, -0.45]))
            bench.addChild(box(0.08, 0.41, 0.08, steel, at: [0, 0.205, 0.45]))
            bench.addChild(box(0.4, 0.04, 0.08, steel, at: [0, 0.02, -0.45]))
            bench.addChild(box(0.4, 0.04, 0.08, steel, at: [0, 0.02, 0.45]))
            bench.position = [x, 0, z]
            bench.orientation = simd_quatf(angle: angle, axis: [0, 1, 0])
            props.addChild(bench)
        }

        // Rolled yoga mats in a rack.
        let matColors: [(CGFloat, CGFloat, CGFloat)] = [(0.3, 0.6, 0.8), (0.8, 0.3, 0.5), (0.4, 0.75, 0.45)]
        for (i, c) in matColors.enumerated() {
            let mat = ModelEntity(mesh: .generateCylinder(height: 0.6, radius: 0.07),
                                  materials: [material(c.0, c.1, c.2, roughness: 0.9)])
            mat.position = [3.8 + Float(i) * 0.17, 0.3, 6.6]
            props.addChild(mat)
        }
    }

    private static func buildPlants(in props: Entity) {
        let pot = material(0.85, 0.83, 0.8, roughness: 0.6)
        let leaves = material(0.16, 0.45, 0.2, roughness: 0.85)
        for (x, z) in [(-6.3, -6.3), (6.3, -6.3), (-6.3, 6.3), (6.3, 6.3)] as [(Float, Float)] {
            let plant = Entity()
            let base = ModelEntity(mesh: .generateCylinder(height: 0.5, radius: 0.22), materials: [pot])
            base.position.y = 0.25
            plant.addChild(base)
            for (i, offset) in [SIMD3<Float>(0, 0.85, 0), [0.12, 1.1, 0.05], [-0.1, 1.25, -0.06], [0.02, 1.45, 0.1]].enumerated() {
                let leaf = ModelEntity(mesh: .generateSphere(radius: 0.28 - Float(i) * 0.04), materials: [leaves])
                leaf.position = offset
                plant.addChild(leaf)
            }
            plant.position = [x, 0, z]
            props.addChild(plant)
        }
    }

    // MARK: Lighting

    private static func buildLights(in root: Entity) {
        let warm = UIColor(red: 1, green: 0.9, blue: 0.78, alpha: 1)
        // Linear light strips between the beams.
        let strip = UnlitMaterial(color: UIColor(red: 1, green: 0.96, blue: 0.88, alpha: 1))
        for x: Float in [-3, 0, 3] {
            for z: Float in [-4.5, -1.5, 1.5, 4.5] {
                root.addChild(box(0.12, 0.04, 2.2, strip, at: [x, height - 0.12, z]))
            }
        }

        // Daylight through the windows: the only shadow-casting light (cheap and stable).
        let sun = Entity()
        sun.components.set(DirectionalLightComponent(color: UIColor(red: 1, green: 0.95, blue: 0.88, alpha: 1),
                                                     intensity: 4000))
        sun.components.set(DirectionalLightComponent.Shadow(maximumDistance: 12, depthBias: 2))
        sun.look(at: [1.5, 0, -1], from: [-6, 6, 2], relativeTo: nil)
        root.addChild(sun)

        // Spotlights on the workout area and the rack.
        for (target, from) in [(SIMD3<Float>(0, 0, -0.5), SIMD3<Float>(0, height - 0.3, 0.8)),
                               (SIMD3<Float>(0, 0.8, -5.9), SIMD3<Float>(0, height - 0.3, -3.5))] {
            let spot = Entity()
            spot.components.set(SpotLightComponent(color: warm, intensity: 22000, innerAngleInDegrees: 30,
                                                   outerAngleInDegrees: 60, attenuationRadius: 10))
            spot.look(at: target, from: from, relativeTo: nil)
            root.addChild(spot)
        }

        // Soft fill from the ceiling.
        for x: Float in [-3.5, 3.5] {
            for z: Float in [-3.5, 3.5] {
                let light = Entity()
                var point = PointLightComponent(color: warm, intensity: 20000, attenuationRadius: 10)
                point.attenuationFalloffExponent = 1.2
                light.components.set(point)
                light.position = [x, height - 0.5, z]
                root.addChild(light)
            }
        }
    }

    // MARK: Helpers

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

    /// Emissive 3D text centred on x = 0, facing +z, with its baseline at y = 0.
    private static func text(_ string: String, size: CGFloat, color: UIColor) -> ModelEntity? {
        let mesh = MeshResource.generateText(string, extrusionDepth: 0.02,
                                             font: .systemFont(ofSize: size, weight: .black),
                                             containerFrame: .zero, alignment: .center, lineBreakMode: .byClipping)
        let e = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        let bounds = e.visualBounds(relativeTo: nil)
        e.position.x = -(bounds.min.x + bounds.extents.x / 2)
        return e
    }

    /// Image-based light from a procedurally drawn warm gradient, so metal and the mirror pick up
    /// a believable indoor tone without any downloaded assets.
    private static func applyWarmLighting(to root: Entity) async {
        guard let image = warmEnvironmentImage(),
              let environment = try? await EnvironmentResource(equirectangular: image, withName: "gymLight") else { return }
        root.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 1.0))
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
            let colors = [UIColor(red: 1.0, green: 0.95, blue: 0.86, alpha: 1).cgColor,
                          UIColor(red: 0.78, green: 0.70, blue: 0.60, alpha: 1).cgColor,
                          UIColor(red: 0.20, green: 0.19, blue: 0.19, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                      locations: [0, 0.5, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
            // Bright window band on one side for highlights on chrome and the mirror.
            UIColor(red: 0.9, green: 0.95, blue: 1, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 30, width: 60, height: 40))
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
