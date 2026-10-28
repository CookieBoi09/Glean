import XCTest
import UIKit
@testable import Glean

final class WidgetStoreTests: XCTestCase {
    func testSnapshotRoundTripKeepsImageNameAndTimestampTogether() throws {
        let timestamp = Date(timeIntervalSince1970: 1_234_567)
        let data = try WidgetStore.encode(
            image: image(size: CGSize(width: 240, height: 120)),
            modelName: "  Crewmate\n",
            updatedAt: timestamp
        )
        let snapshot = try XCTUnwrap(WidgetStore.decode(data))
        XCTAssertEqual(snapshot.modelName, "Crewmate")
        XCTAssertEqual(snapshot.updatedAt, timestamp)
        XCTAssertEqual(snapshot.image.size, CGSize(width: 240, height: 120))
    }

    func testLargeRenderIsBoundedForWidgetMemoryWithoutDistortingAspectRatio() throws {
        let data = try WidgetStore.encode(
            image: image(size: CGSize(width: 2_400, height: 1_200)),
            modelName: "Landscape"
        )
        let snapshot = try XCTUnwrap(WidgetStore.decode(data))
        XCTAssertEqual(snapshot.image.size, CGSize(width: 1_200, height: 600))
        XCTAssertEqual(snapshot.image.scale, 1)
    }

    func testBlankModelNameGetsReadableFallback() throws {
        let data = try WidgetStore.encode(image: image(), modelName: " \n\t ")
        XCTAssertEqual(WidgetStore.decode(data)?.modelName, "My model")
    }

    func testEmptyRenderCannotReplaceSavedSnapshot() {
        XCTAssertThrowsError(try WidgetStore.encode(image: UIImage(), modelName: "Invalid")) { error in
            guard case WidgetStore.StoreError.invalidImage = error else {
                return XCTFail("Expected invalidImage, got \(error)")
            }
        }
    }

    func testCorruptAndFutureVersionSnapshotsFallBackGracefully() throws {
        XCTAssertNil(WidgetStore.decode(Data("not a snapshot".utf8)))
        let data = try WidgetStore.encode(image: image(), modelName: "Crewmate")
        var plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        plist["version"] = 99
        let unsupported = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertNil(WidgetStore.decode(unsupported))
    }

    private func image(size: CGSize = CGSize(width: 80, height: 80)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
