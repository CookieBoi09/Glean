import ModelIO
import SceneKit
import SceneKit.ModelIO
import UIKit

/// Makes the same self-contained scene for interactive viewing and widget snapshots.
enum SceneFactory {
    enum SceneError: LocalizedError {
        case unsupported(String)
        case empty
        case invalidBounds

        var errorDescription: String? {
            switch self {
            case .unsupported(let format):
                return "This device cannot open .\(format) files. Try USDZ, GLB, glTF, OBJ, or a SceneKit scene."
            case .empty:
                return "The file contains no visible 3D geometry. Export a mesh and try again."
            case .invalidBounds:
                return "This model has invalid or empty dimensions and cannot be displayed."
            }
        }
    }

    static func makeScene(modelURL: URL?, color: UIColor = .systemRed) throws -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear
        let pivot = SCNNode()
        pivot.name = "modelPivot"
        scene.rootNode.addChildNode(pivot)

        if let modelURL {
            let imported = try loadModel(at: modelURL)
            // Imported cameras and lights must not change the shared framing or lighting.
            imported.enumerateChildNodes { node, _ in
                node.camera = nil
                node.light = nil
            }
            imported.camera = nil
            imported.light = nil
            guard containsGeometry(imported) else { throw SceneError.empty }
            let normalization = SCNNode()
            normalization.addChildNode(imported)
            let (minimum, maximum) = normalization.boundingBox
            let size = SIMD3<Float>(maximum.x - minimum.x, maximum.y - minimum.y, maximum.z - minimum.z)
            let longest = max(size.x, max(size.y, size.z))
            guard longest.isFinite, longest > 0.000001,
                  [minimum.x, minimum.y, minimum.z, maximum.x, maximum.y, maximum.z].allSatisfy({ $0.isFinite })
            else { throw SceneError.invalidBounds }
            let scale: Float = 2.15 / longest
            let center = SIMD3<Float>((minimum.x + maximum.x) / 2, (minimum.y + maximum.y) / 2, (minimum.z + maximum.z) / 2)
            normalization.simdScale = SIMD3(repeating: scale)
            normalization.simdPosition = -center * scale
            pivot.addChildNode(normalization)
        } else {
            pivot.addChildNode(makeCrewmate(color: color))
            pivot.eulerAngles.y = -0.28
        }

        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 36
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 200
        camera.camera?.wantsHDR = true
        camera.camera?.exposureOffset = 0.2
        camera.position = SCNVector3(0, 0.12, 4.7)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)

        addLight(to: scene, type: .ambient, intensity: 450, color: UIColor(red: 0.72, green: 0.79, blue: 1, alpha: 1), position: SCNVector3Zero)
        addLight(to: scene, type: .omni, intensity: 1100, color: .white, position: SCNVector3(-3, 4, 5))
        addLight(to: scene, type: .omni, intensity: 650, color: UIColor(red: 0.65, green: 0.82, blue: 1, alpha: 1), position: SCNVector3(3, 1, -2))
        return scene
    }

    static func camera(in scene: SCNScene) -> SCNNode {
        scene.rootNode.childNode(withName: "camera", recursively: false)!
    }

    static func content(in scene: SCNScene) -> SCNNode {
        scene.rootNode.childNode(withName: "modelPivot", recursively: false)!
    }

    private static func loadModel(at url: URL) throws -> SCNNode {
        let ext = url.pathExtension.lowercased()
        if ext == "gltf" || ext == "glb" {
            return try GLTFImporter.scene(url: url).rootNode.clone()
        }
        if ["scn", "dae", "usd", "usdz", "usda", "usdc"].contains(ext) {
            return try SCNScene(url: url, options: [.checkConsistency: true]).rootNode.clone()
        }
        guard MDLAsset.canImportFileExtension(ext) else { throw SceneError.unsupported(ext) }
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        return SCNScene(mdlAsset: asset).rootNode.clone()
    }

    private static func containsGeometry(_ node: SCNNode) -> Bool {
        if let geometry = node.geometry, !geometry.sources(for: .vertex).isEmpty, !geometry.elements.isEmpty {
            return true
        }
        return node.childNodes.contains(where: containsGeometry)
    }

    private static func material(color: UIColor, metallic: CGFloat = 0.1, roughness: CGFloat = 0.32) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = metallic
        material.roughness.contents = roughness
        return material
    }

    private static func makeCrewmate(color: UIColor) -> SCNNode {
        let root = SCNNode()
        root.name = "Test crewmate"
        let suit = material(color: color)
        let darkSuit = material(color: color.withAlphaComponent(1), roughness: 0.48)

        let body = SCNCapsule(capRadius: 0.57, height: 1.55)
        body.radialSegmentCount = 48
        body.heightSegmentCount = 24
        body.materials = [suit]
        let bodyNode = SCNNode(geometry: body)
        bodyNode.position.y = 0.2
        root.addChildNode(bodyNode)

        for x: Float in [-0.29, 0.29] {
            let leg = SCNCapsule(capRadius: 0.235, height: 0.69)
            leg.radialSegmentCount = 32
            leg.materials = [darkSuit]
            let node = SCNNode(geometry: leg)
            node.position = SCNVector3(x, -0.64, 0)
            root.addChildNode(node)
        }

        let backpack = SCNBox(width: 0.73, height: 0.94, length: 0.39, chamferRadius: 0.14)
        backpack.chamferSegmentCount = 10
        backpack.materials = [darkSuit]
        let packNode = SCNNode(geometry: backpack)
        packNode.position = SCNVector3(0, 0.15, -0.55)
        root.addChildNode(packNode)

        let rim = SCNBox(width: 1.08, height: 0.64, length: 0.28, chamferRadius: 0.22)
        rim.chamferSegmentCount = 14
        rim.materials = [material(color: UIColor(red: 0.12, green: 0.16, blue: 0.22, alpha: 1), roughness: 0.28)]
        let rimNode = SCNNode(geometry: rim)
        rimNode.position = SCNVector3(0, 0.4, 0.49)
        root.addChildNode(rimNode)

        let visor = SCNBox(width: 0.96, height: 0.51, length: 0.23, chamferRadius: 0.19)
        visor.chamferSegmentCount = 16
        visor.materials = [material(color: UIColor(red: 0.47, green: 0.8, blue: 0.91, alpha: 1), metallic: 0.5, roughness: 0.15)]
        let visorNode = SCNNode(geometry: visor)
        visorNode.position = SCNVector3(0, 0.42, 0.62)
        root.addChildNode(visorNode)

        let highlight = SCNBox(width: 0.43, height: 0.085, length: 0.018, chamferRadius: 0.035)
        highlight.chamferSegmentCount = 8
        let shine = material(color: UIColor.white.withAlphaComponent(0.85), roughness: 0.1)
        shine.emission.contents = UIColor(white: 0.3, alpha: 1)
        highlight.materials = [shine]
        let highlightNode = SCNNode(geometry: highlight)
        highlightNode.position = SCNVector3(-0.1, 0.53, 0.742)
        highlightNode.eulerAngles.z = -0.07
        root.addChildNode(highlightNode)
        return root
    }

    private static func addLight(to scene: SCNScene, type: SCNLight.LightType, intensity: CGFloat, color: UIColor, position: SCNVector3) {
        let node = SCNNode()
        let light = SCNLight()
        light.type = type
        light.intensity = intensity
        light.color = color
        node.light = light
        node.position = position
        scene.rootNode.addChildNode(node)
    }
}
