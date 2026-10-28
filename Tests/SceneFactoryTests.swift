import XCTest
import SceneKit
@testable import Glean

final class SceneFactoryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try FileManager.default.removeItem(at: folder) }
    }

    func testDefaultModelHasVisibleGeometryAndUsableCamera() throws {
        let scene = try SceneFactory.makeScene(modelURL: nil)
        let pivot = try XCTUnwrap(scene.rootNode.childNode(withName: "modelPivot", recursively: false))
        var meshCount = 0
        pivot.enumerateChildNodes { node, _ in if node.geometry != nil { meshCount += 1 } }
        XCTAssertGreaterThan(meshCount, 4)
        let camera = try XCTUnwrap(SceneFactory.camera(in: scene).camera)
        XCTAssertGreaterThan(camera.zFar, camera.zNear)
        XCTAssertGreaterThan(camera.fieldOfView, 0)
        XCTAssertFalse(camera.usesOrthographicProjection)
    }

    func testImportedModelIsCenteredAndNormalizedRegardlessOfSourceUnits() throws {
        let source = SCNScene()
        let box = SCNNode(geometry: SCNBox(width: 80, height: 40, length: 20, chamferRadius: 0))
        box.position = SCNVector3(170, -30, 90)
        source.rootNode.addChildNode(box)
        let url = folder.appendingPathComponent("large-offset-box.scn")
        XCTAssertTrue(source.write(to: url, options: nil, delegate: nil, progressHandler: nil))

        let loaded = try SceneFactory.makeScene(modelURL: url)
        let (minimum, maximum) = SceneFactory.content(in: loaded).boundingBox
        XCTAssertEqual(maximum.x - minimum.x, 2.15, accuracy: 0.001)
        XCTAssertEqual(maximum.y - minimum.y, 1.075, accuracy: 0.001)
        XCTAssertEqual(minimum.x + maximum.x, 0, accuracy: 0.001)
        XCTAssertEqual(minimum.y + maximum.y, 0, accuracy: 0.001)
        XCTAssertEqual(minimum.z + maximum.z, 0, accuracy: 0.001)
    }

    func testEmptySceneFailsInsteadOfDisplayingBlankWidget() throws {
        let url = folder.appendingPathComponent("empty.scn")
        XCTAssertTrue(SCNScene().write(to: url, options: nil, delegate: nil, progressHandler: nil))
        XCTAssertThrowsError(try SceneFactory.makeScene(modelURL: url)) { error in
            guard let sceneError = error as? SceneFactory.SceneError, case .empty = sceneError else {
                return XCTFail("Expected an empty geometry error, received \(error)")
            }
        }
    }
}
