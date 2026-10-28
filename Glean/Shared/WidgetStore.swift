import Foundation
import UIKit

struct WidgetSnapshot {
    let image: UIImage
    let modelName: String
    let updatedAt: Date
}

/// Shared by the app and extension. A single atomic file keeps the render and
/// its metadata consistent even when WidgetKit reads during a save.
enum WidgetStore {
    static var groupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "GleanAppGroup") as? String
            ?? "group.com.example.Glean"
    }

    private static let filename = "widget-snapshot.plist"
    private static let maximumFileSize = 24 * 1_024 * 1_024

    private struct StoredSnapshot: Codable {
        let version: Int
        let image: Data
        let modelName: String
        let updatedAt: Date
    }

    enum StoreError: LocalizedError {
        case appGroupUnavailable
        case invalidImage
        case imageTooLarge

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "The shared widget container is unavailable. Enable the same App Group for Glean and GleanWidgets in Xcode Signing & Capabilities, then reinstall both targets."
            case .invalidImage:
                return "The widget image could not be saved. Render the model again and retry."
            case .imageTooLarge:
                return "The widget image is too large to save. Try a smaller background photo."
            }
        }
    }

    static func save(image: UIImage, modelName: String) throws {
        let data = try encode(image: image, modelName: modelName)
        try data.write(to: fileURL(), options: .atomic)
    }

    /// Separated from container access so serialization can be tested without
    /// a provisioned App Group or touching a user's saved widget.
    static func encode(image: UIImage, modelName: String, updatedAt: Date = Date()) throws -> Data {
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else {
            throw StoreError.invalidImage
        }

        // Bound extension memory use, independently of the source photo size.
        let longestSide: CGFloat = 1_200
        let ratio = min(1, longestSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let boundedImage = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = boundedImage.pngData(), !png.isEmpty else {
            throw StoreError.invalidImage
        }
        let name = String(modelName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let payload = StoredSnapshot(
            version: 1,
            image: png,
            modelName: name.isEmpty ? "My model" : name,
            updatedAt: updatedAt
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(payload)
        guard data.count <= maximumFileSize else { throw StoreError.imageTooLarge }
        return data
    }

    static func decode(_ data: Data) -> WidgetSnapshot? {
        guard data.count <= maximumFileSize,
              let saved = try? PropertyListDecoder().decode(StoredSnapshot.self, from: data),
              saved.version == 1,
              let image = UIImage(data: saved.image),
              image.size.width > 0, image.size.height > 0,
              image.size.width <= 1_200, image.size.height <= 1_200 else { return nil }
        return WidgetSnapshot(image: image, modelName: saved.modelName, updatedAt: saved.updatedAt)
    }

    static func load() -> WidgetSnapshot? {
        do {
            let url = try fileURL()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue <= maximumFileSize else { return nil }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return decode(data)
        } catch {
            // First launch and a removed or unreadable render use the honest
            // "Save a view" state rather than displaying a fake saved model.
            return nil
        }
    }

    static func clear() throws {
        let url = try fileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func fileURL() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else { throw StoreError.appGroupUnavailable }
        return container.appendingPathComponent(filename, isDirectory: false)
    }
}
