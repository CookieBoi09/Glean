import XCTest
import SceneKit
@testable import Glean

final class ModelImporterTests: XCTestCase {
    private var folder: URL!
    private var importedModels: [URL] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for model in importedModels {
            // Imports are in .../Glean/Models/<UUID>/<file> or <UUID>/Asset/<file>.
            let importFolder = model.deletingLastPathComponent().lastPathComponent == "Asset"
                ? model.deletingLastPathComponent().deletingLastPathComponent()
                : model.deletingLastPathComponent()
            try FileManager.default.removeItem(at: importFolder)
        }
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    func testUnsupportedFileIsRejectedWithoutDeletingOriginal() throws {
        let source = folder.appendingPathComponent("project.blend")
        let data = Data("test original".utf8)
        try data.write(to: source)
        XCTAssertThrowsError(try ModelImporter.importModel(from: source)) { error in
            guard let importError = error as? ModelImporter.ImportError, case .unsupported = importError else {
                return XCTFail("Expected unsupported format, received \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), data)
    }

    func testNewImportDoesNotOverwriteAnExistingImportedModel() throws {
        let source = try writeModel(named: "same-name.scn")
        let first = try ModelImporter.importModel(from: source)
        importedModels.append(first)
        let firstData = try Data(contentsOf: first)
        let second = try ModelImporter.importModel(from: source)
        importedModels.append(second)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), firstData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertNoThrow(try SceneFactory.makeScene(modelURL: second))
    }

    func testFolderImportPreservesCompanionResources() throws {
        _ = try writeModel(named: "model.scn")
        let textures = folder.appendingPathComponent("textures", isDirectory: true)
        try FileManager.default.createDirectory(at: textures, withIntermediateDirectories: true)
        let textureData = Data([1, 2, 3, 4])
        try textureData.write(to: textures.appendingPathComponent("texture.bin"))
        let imported = try ModelImporter.importModel(from: folder)
        importedModels.append(imported)
        let copiedTexture = imported.deletingLastPathComponent().appendingPathComponent("textures/texture.bin")
        XCTAssertEqual(try Data(contentsOf: copiedTexture), textureData)
    }

    func testFolderWithMultipleModelsRequiresUnambiguousSelection() throws {
        _ = try writeModel(named: "first.scn")
        _ = try writeModel(named: "second.scn")
        XCTAssertThrowsError(try ModelImporter.importModel(from: folder)) { error in
            guard let importError = error as? ModelImporter.ImportError, case .ambiguousFolder = importError else {
                return XCTFail("Expected ambiguous folder, received \(error)")
            }
        }
    }

    func testFolderSymlinkIsRejected() throws {
        let source = try writeModel(named: "model.scn")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.scn"), withDestinationURL: source)
        XCTAssertThrowsError(try ModelImporter.importModel(from: folder)) { error in
            guard let importError = error as? ModelImporter.ImportError, case .symbolicLink = importError else {
                return XCTFail("Expected symbolic-link rejection, received \(error)")
            }
        }
    }

    func testOBJReferencingMaterialsRequiresFolderImport() throws {
        let source = folder.appendingPathComponent("model.obj")
        try "mtllib\tmodel.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ModelImporter.importModel(from: source)) { error in
            guard let importError = error as? ModelImporter.ImportError, case .folderRequired = importError else {
                return XCTFail("Expected folder import guidance, received \(error)")
            }
        }
    }

    private func writeModel(named name: String) throws -> URL {
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 1, height: 2, length: 1, chamferRadius: 0)))
        let url = folder.appendingPathComponent(name)
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }
}
