import XCTest
import SceneKit
@testable import Glean

final class GLTFImporterTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    func testEmbeddedTriangleLoadsAndGeneratesNormals() throws {
        let url = try writeJSON(triangleDocument())
        let scene = try GLTFImporter.scene(url: url)
        let mesh = try XCTUnwrap(scene.rootNode.childNodes.first?.childNodes.first?.geometry)
        XCTAssertEqual(mesh.sources(for: .vertex).first?.vectorCount, 3)
        XCTAssertEqual(mesh.sources(for: .normal).first?.vectorCount, 3)
        XCTAssertEqual(mesh.elements.first?.primitiveCount, 1)
    }

    func testBinaryGLBTriangleLoads() throws {
        var document = triangleDocument()
        let binary = vertices()
        document["buffers"] = [["byteLength": binary.count]]
        var json = try JSONSerialization.data(withJSONObject: document)
        while json.count % 4 != 0 { json.append(0x20) }
        var glb = Data()
        append(0x46546C67, to: &glb)
        append(2, to: &glb)
        append(UInt32(12 + 8 + json.count + 8 + binary.count), to: &glb)
        append(UInt32(json.count), to: &glb)
        append(0x4E4F534A, to: &glb)
        glb.append(json)
        append(UInt32(binary.count), to: &glb)
        append(0x004E4942, to: &glb)
        glb.append(binary)
        let url = folder.appendingPathComponent("triangle.glb")
        try glb.write(to: url)
        XCTAssertNoThrow(try GLTFImporter.scene(url: url))
    }

    func testTruncatedGLBIsRejected() throws {
        let url = folder.appendingPathComponent("broken.glb")
        try Data([0x67, 0x6c, 0x54, 0x46]).write(to: url)
        XCTAssertThrowsError(try GLTFImporter.scene(url: url))
    }

    func testAccessorOutsideBufferIsRejected() throws {
        var document = triangleDocument()
        document["accessors"] = [["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3"]]
        XCTAssertThrowsError(try GLTFImporter.scene(url: writeJSON(document)))
    }

    func testOutOfRangeTriangleIndexIsRejected() throws {
        var document = triangleDocument()
        var data = vertices()
        data.append(contentsOf: [0, 0, 1, 0, 4, 0])
        document["buffers"] = [["byteLength": data.count, "uri": "data:application/octet-stream;base64," + data.base64EncodedString()]]
        document["bufferViews"] = [["buffer": 0, "byteLength": 36], ["buffer": 0, "byteOffset": 36, "byteLength": 6]]
        document["accessors"] = [
            ["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"],
            ["bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"]
        ]
        document["meshes"] = [["primitives": [["attributes": ["POSITION": 0], "indices": 1]]]]
        XCTAssertThrowsError(try GLTFImporter.scene(url: writeJSON(document)))
    }

    func testOversizedAccessorOffsetIsRejectedWithoutOverflow() throws {
        var document = triangleDocument()
        document["accessors"] = [["bufferView": 0, "byteOffset": Int.max, "componentType": 5126, "count": 3, "type": "VEC3"]]
        XCTAssertThrowsError(try GLTFImporter.scene(url: writeJSON(document)))
    }

    func testRequiredCompressionExtensionIsRejected() throws {
        var document = triangleDocument()
        document["extensionsRequired"] = ["KHR_draco_mesh_compression"]
        XCTAssertThrowsError(try GLTFImporter.scene(url: writeJSON(document)))
    }

    func testExternalPathCannotEscapeModelFolder() throws {
        var document = triangleDocument()
        document["buffers"] = [["byteLength": 36, "uri": "../private.bin"]]
        XCTAssertThrowsError(try GLTFImporter.scene(url: writeJSON(document))) { error in
            XCTAssertTrue(error.localizedDescription.contains("escapes the model folder"))
        }
    }

    func testRemoteResourcesAreRejected() throws {
        var document = triangleDocument()
        document["buffers"] = [["byteLength": 36, "uri": "https://example.com/model.bin"]]
        XCTAssertThrowsError(try GLTFImporter.scene(url: writeJSON(document))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Remote or absolute"))
        }
    }

    func testCyclicHierarchyIsRejected() throws {
        var document = triangleDocument()
        document["nodes"] = [["mesh": 0, "children": [0]]]
        XCTAssertThrowsError(try GLTFImporter.scene(url: writeJSON(document)))
    }

    func testSkinIsRejectedRatherThanRenderedIncorrectly() throws {
        var document = triangleDocument()
        document["nodes"] = [["mesh": 0, "skin": 0]]
        XCTAssertThrowsError(try GLTFImporter.scene(url: writeJSON(document)))
    }

    private func triangleDocument() -> [String: Any] {
        let data = vertices()
        return [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": [["attributes": ["POSITION": 0]]]]],
            "buffers": [["byteLength": data.count, "uri": "data:application/octet-stream;base64," + data.base64EncodedString()]],
            "bufferViews": [["buffer": 0, "byteLength": data.count]],
            "accessors": [["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"]]
        ]
    }

    private func vertices() -> Data {
        var data = Data()
        let coordinates: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
        for number in coordinates { append(number.bitPattern, to: &data) }
        return data
    }

    private func append(_ number: UInt32, to data: inout Data) {
        var value = number.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func writeJSON(_ document: [String: Any]) throws -> URL {
        let url = folder.appendingPathComponent(UUID().uuidString + ".gltf")
        try JSONSerialization.data(withJSONObject: document).write(to: url)
        return url
    }
}
