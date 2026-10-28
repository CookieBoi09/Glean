import Foundation
import ImageIO
import simd
import SceneKit
import UIKit

/// A deliberately bounded glTF 2.0 static-mesh reader. No remote resources are fetched.
/// Animation, skinning, morph targets and required extensions are rejected explicitly.
enum GLTFImporter {
    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): return "This glTF model could not be opened. \(message)" }
        }
    }

    static func scene(url: URL) throws -> SCNScene {
        try Reader(url: url).makeScene()
    }

    private static let maximumBytes = 128 * 1_024 * 1_024
    private static let maximumVertices = 1_000_000

    private struct Document: Decodable {
        var asset: Asset
        var scene: Int?
        var scenes: [Scene]?
        var nodes: [Node]?
        var meshes: [Mesh]?
        var accessors: [Accessor]?
        var bufferViews: [BufferView]?
        var buffers: [Buffer]?
        var materials: [Material]?
        var textures: [Texture]?
        var images: [Image]?
        var samplers: [Sampler]?
        var extensionsRequired: [String]?
        var animations: [Animation]?
    }
    private struct Animation: Decodable {}
    private struct Asset: Decodable { var version: String; var minVersion: String? }
    private struct Scene: Decodable { var nodes: [Int]? }
    private struct Node: Decodable {
        var name: String?
        var mesh: Int?
        var children: [Int]?
        var matrix: [Float]?
        var translation: [Float]?
        var rotation: [Float]?
        var scale: [Float]?
        var skin: Int?
        var weights: [Float]?
    }
    private struct Mesh: Decodable { var primitives: [Primitive]; var weights: [Float]? }
    private struct Primitive: Decodable {
        var attributes: [String: Int]
        var indices: Int?
        var material: Int?
        var mode: Int?
        var targets: [[String: Int]]?
        var extensions: [String: IgnoredValue]?
    }
    private struct IgnoredValue: Decodable { init(from decoder: Decoder) throws {} }
    private struct Accessor: Decodable {
        var bufferView: Int?
        var byteOffset: Int?
        var componentType: Int
        var normalized: Bool?
        var count: Int
        var type: String
        var sparse: IgnoredValue?
    }
    private struct BufferView: Decodable {
        var buffer: Int
        var byteOffset: Int?
        var byteLength: Int
        var byteStride: Int?
        var extensions: [String: IgnoredValue]?
    }
    private struct Buffer: Decodable { var byteLength: Int; var uri: String? }
    private struct Material: Decodable {
        var name: String?
        var pbrMetallicRoughness: PBR?
        var doubleSided: Bool?
        var alphaMode: String?
        var alphaCutoff: Float?
        var emissiveFactor: [Float]?
    }
    private struct PBR: Decodable {
        var baseColorFactor: [Float]?
        var baseColorTexture: TextureInfo?
        var metallicFactor: Float?
        var roughnessFactor: Float?
    }
    private struct TextureInfo: Decodable { var index: Int; var texCoord: Int? }
    private struct Texture: Decodable { var source: Int?; var sampler: Int? }
    private struct Image: Decodable { var uri: String?; var bufferView: Int?; var mimeType: String? }
    private struct Sampler: Decodable { var wrapS: Int?; var wrapT: Int? }

    private final class Reader {
        let url: URL
        let document: Document
        let buffers: [Data]
        var geometryCount = 0
        var instantiatedNodes = 0
        var totalVertices = 0
        var totalIndices = 0
        var totalImagePixels = 0
        var totalImageBytes = 0
        var totalMaterialTexturePixels = 0
        var geometries: [Int: [SCNGeometry]] = [:]
        var materials: [Int: SCNMaterial] = [:]
        var images: [Int: UIImage] = [:]

        init(url: URL) throws {
            self.url = url
            let file = try Self.readFile(url)
            let json: Data
            var binary: Data?
            if url.pathExtension.lowercased() == "glb" {
                guard file.count >= 20, Self.uint32(file, 0) == 0x46546C67,
                      Self.uint32(file, 4) == 2, Int(Self.uint32(file, 8)) == file.count else {
                    throw ImportError.invalid("Invalid GLB 2.0 header or file length.")
                }
                var offset = 12
                var jsonChunk: Data?
                while offset < file.count {
                    guard offset <= file.count - 8 else { throw ImportError.invalid("Truncated GLB chunk.") }
                    let count = Int(Self.uint32(file, offset))
                    let kind = Self.uint32(file, offset + 4)
                    offset += 8
                    guard count % 4 == 0, count <= file.count - offset else {
                        throw ImportError.invalid("Invalid GLB chunk length.")
                    }
                    if jsonChunk == nil && kind != 0x4E4F534A {
                        throw ImportError.invalid("The first GLB chunk must contain JSON.")
                    }
                    if kind == 0x4E4F534A {
                        guard jsonChunk == nil else { throw ImportError.invalid("Duplicate JSON chunk.") }
                        jsonChunk = file.subdata(in: offset..<(offset + count))
                    } else if kind == 0x004E4942 {
                        guard binary == nil else { throw ImportError.invalid("Duplicate binary chunk.") }
                        binary = file.subdata(in: offset..<(offset + count))
                    }
                    offset += count
                }
                guard let chunk = jsonChunk else { throw ImportError.invalid("Missing GLB JSON chunk.") }
                json = chunk
            } else { json = file }
            let decoded: Document
            do { decoded = try JSONDecoder().decode(Document.self, from: json) }
            catch { throw ImportError.invalid("The JSON structure is invalid: \(error.localizedDescription)") }
            guard decoded.asset.version == "2.0", decoded.asset.minVersion == nil || decoded.asset.minVersion == "2.0" else {
                throw ImportError.invalid("Export the model as glTF 2.0.")
            }
            guard (decoded.extensionsRequired ?? []).isEmpty else {
                throw ImportError.invalid("Required extensions are unsupported: \((decoded.extensionsRequired ?? []).joined(separator: ", ")). Export an uncompressed static mesh.")
            }
            guard (decoded.animations ?? []).isEmpty else {
                throw ImportError.invalid("Animated glTF is not supported. Export a static pose or use USDZ.")
            }
            guard (decoded.nodes ?? []).count <= 10_000,
                  (decoded.meshes ?? []).count <= 2_000,
                  (decoded.buffers ?? []).count <= 1_000 else {
                throw ImportError.invalid("The model exceeds the scene complexity limit.")
            }
            self.document = decoded
            var loaded: [Data] = []
            var total = file.count
            for (index, item) in (decoded.buffers ?? []).enumerated() {
                guard item.byteLength >= 0, item.byteLength <= maximumBytes else {
                    throw ImportError.invalid("Invalid or oversized buffer.")
                }
                let data: Data
                if let uri = item.uri { data = try Self.resource(uri, relativeTo: url) }
                else if index == 0, let binary { data = binary }
                else { throw ImportError.invalid("A mesh buffer is missing.") }
                guard data.count >= item.byteLength, total <= maximumBytes - data.count else {
                    throw ImportError.invalid("Mesh buffers are truncated or exceed the 128 MB import limit.")
                }
                total += data.count
                loaded.append(data.prefix(item.byteLength))
            }
            buffers = loaded
        }

        func makeScene() throws -> SCNScene {
            let result = SCNScene()
            let nodes = document.nodes ?? []
            let rootIndices: [Int]
            if let scenes = document.scenes, !scenes.isEmpty {
                let selected = document.scene ?? 0
                rootIndices = try item(scenes, selected, "scene").nodes ?? []
            } else {
                let childIndices = Set(nodes.flatMap { $0.children ?? [] })
                rootIndices = nodes.indices.filter { !childIndices.contains($0) }
            }
            for index in rootIndices {
                result.rootNode.addChildNode(try makeNode(index, ancestors: []))
            }
            guard geometryCount > 0 else { throw ImportError.invalid("The selected scene contains no triangle meshes.") }
            return result
        }

        private func makeNode(_ index: Int, ancestors: Set<Int>) throws -> SCNNode {
            guard !ancestors.contains(index), ancestors.count < 64, instantiatedNodes < 10_000 else {
                throw ImportError.invalid("The scene hierarchy is cyclic or too large.")
            }
            instantiatedNodes += 1
            let source = try item(document.nodes ?? [], index, "node")
            guard source.skin == nil, source.weights == nil else {
                throw ImportError.invalid("Skinned or morphing models are unsupported. Export a static pose.")
            }
            let node = SCNNode()
            node.name = source.name
            if let matrix = source.matrix {
                guard matrix.count == 16, matrix.allSatisfy(\.isFinite),
                      source.translation == nil, source.rotation == nil, source.scale == nil else {
                    throw ImportError.invalid("Invalid node transform.")
                }
                node.simdTransform = simd_float4x4(
                    SIMD4(matrix[0], matrix[1], matrix[2], matrix[3]),
                    SIMD4(matrix[4], matrix[5], matrix[6], matrix[7]),
                    SIMD4(matrix[8], matrix[9], matrix[10], matrix[11]),
                    SIMD4(matrix[12], matrix[13], matrix[14], matrix[15]))
            } else {
                if let t = source.translation {
                    try validate(t, count: 3, label: "translation")
                    node.simdPosition = SIMD3(t[0], t[1], t[2])
                }
                if let r = source.rotation {
                    try validate(r, count: 4, label: "rotation")
                    let length = sqrt(r.reduce(Float(0)) { $0 + $1 * $1 })
                    guard length.isFinite, length > 0.00001 else { throw ImportError.invalid("Invalid rotation quaternion.") }
                    node.simdOrientation = simd_quatf(ix: r[0] / length, iy: r[1] / length, iz: r[2] / length, r: r[3] / length)
                }
                if let s = source.scale {
                    try validate(s, count: 3, label: "scale")
                    node.simdScale = SIMD3(s[0], s[1], s[2])
                }
            }
            if let mesh = source.mesh {
                for geometry in try meshGeometries(mesh) {
                    node.addChildNode(SCNNode(geometry: geometry))
                    geometryCount += 1
                }
            }
            var descendants = ancestors
            descendants.insert(index)
            for child in source.children ?? [] {
                node.addChildNode(try makeNode(child, ancestors: descendants))
            }
            return node
        }

        private func meshGeometries(_ index: Int) throws -> [SCNGeometry] {
            if let cached = geometries[index] { return cached }
            let mesh = try item(document.meshes ?? [], index, "mesh")
            guard mesh.weights == nil, mesh.primitives.count <= 1_000 else {
                throw ImportError.invalid("Morph targets or too many mesh primitives.")
            }
            let result = try mesh.primitives.map { primitive -> SCNGeometry in
                guard (primitive.mode ?? 4) == 4 else {
                    throw ImportError.invalid("Only triangle meshes are supported. Triangulate the model before exporting.")
                }
                guard primitive.targets == nil,
                      primitive.extensions?["KHR_draco_mesh_compression"] == nil,
                      let positionIndex = primitive.attributes["POSITION"] else {
                    throw ImportError.invalid("Compressed meshes, morph targets, or missing positions. Export an uncompressed static mesh.")
                }
                let positions = try floatAttribute(positionIndex, type: "VEC3", components: 3, allowNormalized: false)
                let vertexCount = positions.count / 3
                guard vertexCount > 0, totalVertices <= maximumVertices - vertexCount else {
                    throw ImportError.invalid("The model exceeds one million vertices.")
                }
                totalVertices += vertexCount
                let vertices = stride(from: 0, to: positions.count, by: 3).map {
                    SCNVector3(positions[$0], positions[$0 + 1], positions[$0 + 2])
                }
                var sources = [SCNGeometrySource(vertices: vertices)]
                if let normalIndex = primitive.attributes["NORMAL"] {
                    let normals = try floatAttribute(normalIndex, type: "VEC3", components: 3, allowNormalized: false)
                    guard normals.count == positions.count else { throw ImportError.invalid("Normal and vertex counts differ.") }
                    sources.append(SCNGeometrySource(normals: stride(from: 0, to: normals.count, by: 3).map {
                        SCNVector3(normals[$0], normals[$0 + 1], normals[$0 + 2])
                    }))
                }
                if let uvIndex = primitive.attributes["TEXCOORD_0"] {
                    let uv = try floatAttribute(uvIndex, type: "VEC2", components: 2, allowNormalized: true)
                    guard uv.count / 2 == vertexCount else { throw ImportError.invalid("Texture coordinate and vertex counts differ.") }
                    sources.append(SCNGeometrySource(textureCoordinates: stride(from: 0, to: uv.count, by: 2).map {
                        CGPoint(x: CGFloat(uv[$0]), y: CGFloat(uv[$0 + 1]))
                    }))
                }
                let indices: [UInt32]
                if let accessorIndex = primitive.indices { indices = try indexAttribute(accessorIndex) }
                else { indices = (0..<vertexCount).map(UInt32.init) }
                guard !indices.isEmpty, indices.count % 3 == 0,
                      totalIndices <= 6_000_000 - indices.count,
                      indices.allSatisfy({ $0 < UInt32(vertexCount) }) else {
                    throw ImportError.invalid("Triangle indices are invalid, out of bounds, or exceed the six-million index limit.")
                }
                totalIndices += indices.count
                if primitive.attributes["NORMAL"] == nil {
                    var normals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
                    for triangle in stride(from: 0, to: indices.count, by: 3) {
                        let a = Int(indices[triangle]), b = Int(indices[triangle + 1]), c = Int(indices[triangle + 2])
                        let va = SIMD3(positions[a * 3], positions[a * 3 + 1], positions[a * 3 + 2])
                        let vb = SIMD3(positions[b * 3], positions[b * 3 + 1], positions[b * 3 + 2])
                        let vc = SIMD3(positions[c * 3], positions[c * 3 + 1], positions[c * 3 + 2])
                        let normal = simd_cross(vb - va, vc - va)
                        normals[a] += normal; normals[b] += normal; normals[c] += normal
                    }
                    sources.append(SCNGeometrySource(normals: normals.map {
                        let length = simd_length($0)
                        let n = length.isFinite && length > 0.00001 ? $0 / length : SIMD3<Float>(0, 1, 0)
                        return SCNVector3(n.x, n.y, n.z)
                    }))
                }
                var indexData = Data(capacity: indices.count * 4)
                for var index in indices.map(\.littleEndian) {
                    withUnsafeBytes(of: &index) { indexData.append(contentsOf: $0) }
                }
                let element = SCNGeometryElement(data: indexData, primitiveType: .triangles, primitiveCount: indices.count / 3, bytesPerIndex: 4)
                let geometry = SCNGeometry(sources: sources, elements: [element])
                geometry.materials = [try material(primitive.material)]
                return geometry
            }
            geometries[index] = result
            return result
        }

        private func material(_ index: Int?) throws -> SCNMaterial {
            guard let index else {
                let result = SCNMaterial()
                result.lightingModel = .physicallyBased
                result.diffuse.contents = UIColor(white: 0.8, alpha: 1)
                result.metalness.contents = 1.0
                result.roughness.contents = 1.0
                return result
            }
            if let cached = materials[index] { return cached }
            let source = try item(document.materials ?? [], index, "material")
            let result = SCNMaterial()
            result.name = source.name
            result.lightingModel = .physicallyBased
            result.isDoubleSided = source.doubleSided ?? false
            let pbr = source.pbrMetallicRoughness
            let color = pbr?.baseColorFactor ?? [1, 1, 1, 1]
            try validate(color, count: 4, label: "base color")
            guard color.allSatisfy({ (0...1).contains($0) }) else { throw ImportError.invalid("Invalid base color factor.") }
            result.diffuse.contents = UIColor(red: CGFloat(color[0]), green: CGFloat(color[1]), blue: CGFloat(color[2]), alpha: CGFloat(color[3]))
            if let textureInfo = pbr?.baseColorTexture {
                guard (textureInfo.texCoord ?? 0) == 0 else { throw ImportError.invalid("Only the first texture coordinate set is supported.") }
                let texture = try item(document.textures ?? [], textureInfo.index, "texture")
                guard let imageIndex = texture.source else { throw ImportError.invalid("A texture image is missing.") }
                let image = try image(imageIndex)
                // SceneKit has no separate base-color multiplier; bake that factor into the image.
                let pixels = Int(image.size.width) * Int(image.size.height)
                guard totalMaterialTexturePixels <= 33_554_432 - pixels else {
                    throw ImportError.invalid("The scene exceeds the material texture memory limit.")
                }
                totalMaterialTexturePixels += pixels
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let tinted = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
                    let rect = CGRect(origin: .zero, size: image.size)
                    image.draw(in: rect)
                    context.cgContext.setBlendMode(.multiply)
                    UIColor(red: CGFloat(color[0]), green: CGFloat(color[1]), blue: CGFloat(color[2]), alpha: 1).setFill()
                    context.fill(rect)
                    context.cgContext.setBlendMode(.destinationIn)
                    image.draw(in: rect)
                }
                result.diffuse.contents = tinted
                result.transparency = CGFloat(color[3])
                if let samplerIndex = texture.sampler {
                    let sampler = try item(document.samplers ?? [], samplerIndex, "sampler")
                    result.diffuse.wrapS = try wrapMode(sampler.wrapS ?? 10497)
                    result.diffuse.wrapT = try wrapMode(sampler.wrapT ?? 10497)
                } else {
                    result.diffuse.wrapS = .repeat
                    result.diffuse.wrapT = .repeat
                }
            }
            let metallic = pbr?.metallicFactor ?? 1
            let roughness = pbr?.roughnessFactor ?? 1
            guard metallic.isFinite, roughness.isFinite, (0...1).contains(metallic), (0...1).contains(roughness) else {
                throw ImportError.invalid("Invalid material factors.")
            }
            result.metalness.contents = metallic
            result.roughness.contents = roughness
            if let emission = source.emissiveFactor {
                try validate(emission, count: 3, label: "emission")
                result.emission.contents = UIColor(red: CGFloat(emission[0]), green: CGFloat(emission[1]), blue: CGFloat(emission[2]), alpha: 1)
            }
            switch source.alphaMode ?? "OPAQUE" {
            case "OPAQUE": result.transparencyMode = .aOne; result.blendMode = .replace
            case "BLEND": result.transparencyMode = .aOne; result.blendMode = .alpha
            case "MASK":
                // Alpha cutoff has no exact built-in material mapping: use a bounded fragment modifier.
                let cutoff = source.alphaCutoff ?? 0.5
                guard cutoff.isFinite, (0...1).contains(cutoff) else { throw ImportError.invalid("Invalid alpha cutoff.") }
                result.shaderModifiers = [.fragment: "#pragma body\nif (_output.color.a < \(cutoff)) { discard_fragment(); } _output.color.a = 1.0;"]
            default: throw ImportError.invalid("Unknown alpha mode.")
            }
            materials[index] = result
            return result
        }

        private func image(_ index: Int) throws -> UIImage {
            if let cached = images[index] { return cached }
            let source = try item(document.images ?? [], index, "image")
            let data: Data
            if let uri = source.uri { data = try Self.resource(uri, relativeTo: url) }
            else if let view = source.bufferView {
                let (buffer, start, length, _) = try viewRange(view)
                data = buffer.subdata(in: start..<(start + length))
            } else { throw ImportError.invalid("An image has no source.") }
            guard data.count <= 16 * 1_024 * 1_024,
                  totalImageBytes <= maximumBytes - data.count,
                  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8_192, height <= 8_192,
                  width * height <= 16_777_216,
                  totalImagePixels <= 33_554_432 - width * height,
                  let image = UIImage(data: data) else {
                throw ImportError.invalid("A texture is invalid, exceeds 16 megapixels, or the scene exceeds 32 megapixels of textures.")
            }
            totalImagePixels += width * height
            totalImageBytes += data.count
            images[index] = image
            return image
        }

        private func wrapMode(_ value: Int) throws -> SCNWrapMode {
            switch value {
            case 10497: return .repeat
            case 33071: return .clamp
            case 33648: return .mirror
            default: throw ImportError.invalid("Invalid texture wrap mode.")
            }
        }

        private func floatAttribute(_ index: Int, type: String, components: Int, allowNormalized: Bool) throws -> [Float] {
            let accessor = try item(document.accessors ?? [], index, "accessor")
            let bytes: Int
            if accessor.componentType == 5126 { bytes = 4 }
            else if allowNormalized && accessor.normalized == true && accessor.componentType == 5121 { bytes = 1 }
            else if allowNormalized && accessor.normalized == true && accessor.componentType == 5123 { bytes = 2 }
            else { throw ImportError.invalid("An attribute has an unsupported component type.") }
            let (data, offset, stride) = try accessorRange(accessor, type: type, elementSize: bytes * components)
            var result: [Float] = []
            result.reserveCapacity(accessor.count * components)
            for row in 0..<accessor.count {
                for column in 0..<components {
                    let position = offset + row * stride + column * bytes
                    let value: Float
                    if bytes == 4 { value = Float(bitPattern: Self.uint32(data, position)) }
                    else if bytes == 2 { value = Float(Self.uint16(data, position)) / 65_535 }
                    else { value = Float(data[position]) / 255 }
                    guard value.isFinite, abs(value) <= 1_000_000 else {
                        throw ImportError.invalid("An attribute contains invalid or extreme coordinates.")
                    }
                    result.append(value)
                }
            }
            return result
        }

        private func indexAttribute(_ index: Int) throws -> [UInt32] {
            let accessor = try item(document.accessors ?? [], index, "index accessor")
            let bytes: Int
            switch accessor.componentType {
            case 5121: bytes = 1
            case 5123: bytes = 2
            case 5125: bytes = 4
            default: throw ImportError.invalid("Triangle indices must be unsigned integers.")
            }
            guard accessor.normalized != true else { throw ImportError.invalid("Indices cannot be normalized.") }
            let (data, offset, stride) = try accessorRange(accessor, type: "SCALAR", elementSize: bytes, maximumCount: 6_000_000)
            return (0..<accessor.count).map { row in
                let position = offset + row * stride
                if bytes == 4 { return Self.uint32(data, position) }
                if bytes == 2 { return UInt32(Self.uint16(data, position)) }
                return UInt32(data[position])
            }
        }

        private func accessorRange(_ accessor: Accessor, type: String, elementSize: Int, maximumCount: Int = maximumVertices) throws -> (Data, Int, Int) {
            guard accessor.type == type, accessor.sparse == nil, accessor.count > 0,
                  accessor.count <= maximumCount, let viewIndex = accessor.bufferView else {
                throw ImportError.invalid("Invalid, sparse, or oversized mesh accessor.")
            }
            let (data, base, length, explicitStride) = try viewRange(viewIndex)
            let offset = accessor.byteOffset ?? 0
            let stride = explicitStride ?? elementSize
            guard offset >= 0, offset <= length, stride >= elementSize, stride <= 252,
                  elementSize <= length - offset,
                  accessor.count - 1 <= (length - offset - elementSize) / stride else {
                throw ImportError.invalid("An accessor points outside its mesh buffer.")
            }
            return (data, base + offset, stride)
        }

        private func viewRange(_ index: Int) throws -> (Data, Int, Int, Int?) {
            let view = try item(document.bufferViews ?? [], index, "buffer view")
            guard view.extensions?["EXT_meshopt_compression"] == nil else {
                throw ImportError.invalid("Meshopt compression is unsupported. Export an uncompressed mesh.")
            }
            let buffer = try item(buffers, view.buffer, "buffer")
            let offset = view.byteOffset ?? 0
            guard offset >= 0, view.byteLength >= 0, offset <= buffer.count,
                  view.byteLength <= buffer.count - offset else {
                throw ImportError.invalid("A buffer view points outside its buffer.")
            }
            return (buffer, offset, view.byteLength, view.byteStride)
        }

        private func item<T>(_ collection: [T], _ index: Int, _ label: String) throws -> T {
            guard collection.indices.contains(index) else { throw ImportError.invalid("Invalid \(label) reference.") }
            return collection[index]
        }

        private func validate(_ values: [Float], count: Int, label: String) throws {
            guard values.count == count, values.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else {
                throw ImportError.invalid("Invalid \(label).")
            }
        }

        private static func resource(_ uri: String, relativeTo modelURL: URL) throws -> Data {
            guard uri.utf8.count <= maximumBytes * 2 else { throw ImportError.invalid("Resource URI is too long.") }
            if uri.hasPrefix("data:") {
                guard let separator = uri.firstIndex(of: ","),
                      uri[..<separator].hasSuffix(";base64"),
                      let data = Data(base64Encoded: String(uri[uri.index(after: separator)...])),
                      data.count <= maximumBytes else {
                    throw ImportError.invalid("Invalid embedded base64 resource.")
                }
                return data
            }
            guard let decoded = uri.removingPercentEncoding,
                  !decoded.hasPrefix("/"), !decoded.contains("\\"),
                  let components = URLComponents(string: decoded), components.scheme == nil,
                  components.host == nil, components.query == nil, components.fragment == nil else {
                throw ImportError.invalid("Remote or absolute resource paths are not allowed. Embed resources in a GLB instead.")
            }
            let root = modelURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            let target = root.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
            guard target.path.hasPrefix(root.path + "/") else {
                throw ImportError.invalid("A resource escapes the model folder. Embed resources in a GLB instead.")
            }
            return try readFile(target)
        }

        private static func readFile(_ url: URL) throws -> Data {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true, let size = attributes.fileSize,
                  size >= 0, size <= maximumBytes else { throw ImportError.invalid("File is invalid or larger than 128 MB.") }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= maximumBytes else { throw ImportError.invalid("File exceeds 128 MB.") }
            return data
        }

        private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
            UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }
    }
}
