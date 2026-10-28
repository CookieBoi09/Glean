import SwiftUI
import SceneKit
import WidgetKit
import ImageIO

@MainActor
final class StudioModel: ObservableObject {
    @Published var scene: SCNScene
    @Published var modelName = "Little crewmate"
    @Published var background: UIImage?
    @Published var selectedColor = 0
    @Published var manualYaw: Double = -0.25
    @Published var manualPitch: Double = 0
    @Published var zoom: Double = 1
    @Published var tiltEnabled = true
    @Published var sensitivity: Double = 1.25
    @Published var isImporting = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var savedMessage: String?
    @Published var usingDefault = true

    static let palette: [UIColor] = [
        UIColor(red: 0.94, green: 0.20, blue: 0.27, alpha: 1),
        UIColor(red: 0.52, green: 0.39, blue: 0.97, alpha: 1),
        UIColor(red: 0.20, green: 0.78, blue: 0.72, alpha: 1),
        UIColor(red: 0.98, green: 0.73, blue: 0.25, alpha: 1),
        UIColor(red: 0.90, green: 0.91, blue: 0.95, alpha: 1)
    ]
    static let colorNames = ["Coral", "Lilac", "Mint", "Gold", "Cloud"]
    private var modelURL: URL?
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glean", isDirectory: true)
    }
    private static var photoURL: URL { support.appendingPathComponent("background.jpg") }

    init() {
        // Procedural geometry has no external resources and cannot fail to load.
        scene = (try? SceneFactory.makeScene(modelURL: nil)) ?? SCNScene()
        let defaults = UserDefaults.standard
        selectedColor = min(max(defaults.integer(forKey: "modelColor"), 0), Self.palette.count - 1)
        if defaults.object(forKey: "tiltEnabled") != nil { tiltEnabled = defaults.bool(forKey: "tiltEnabled") }
        if defaults.object(forKey: "sensitivity") != nil { sensitivity = defaults.double(forKey: "sensitivity") }
        if let name = defaults.string(forKey: "modelRelativePath") {
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(name)
            do {
                scene = try SceneFactory.makeScene(modelURL: url)
                modelURL = url
                modelName = url.deletingPathExtension().lastPathComponent
                usingDefault = false
            } catch {
                errorMessage = "Your saved model couldn’t be reopened. The test model is available instead. \(error.localizedDescription)"
            }
        }
        if usingDefault { scene = (try? SceneFactory.makeScene(modelURL: nil, color: Self.palette[selectedColor])) ?? scene }
        if let data = try? Data(contentsOf: Self.photoURL) { background = UIImage(data: data) }
    }

    func setColor(_ index: Int) {
        guard Self.palette.indices.contains(index), usingDefault else { return }
        do {
            scene = try SceneFactory.makeScene(modelURL: nil, color: Self.palette[index])
            selectedColor = index
            UserDefaults.standard.set(index, forKey: "modelColor")
            savedMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func useDefault() {
        do {
            scene = try SceneFactory.makeScene(modelURL: nil, color: Self.palette[selectedColor])
            modelURL = nil
            usingDefault = true
            modelName = "Little crewmate"
            UserDefaults.standard.removeObject(forKey: "modelRelativePath")
            resetView()
            savedMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func importModel(_ url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try ModelImporter.importModel(from: url)
            }.value
            let nextScene = try SceneFactory.makeScene(modelURL: imported)
            scene = nextScene
            modelURL = imported
            modelName = imported.deletingPathExtension().lastPathComponent
            usingDefault = false
            let supportPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path + "/"
            if imported.path.hasPrefix(supportPath) {
                UserDefaults.standard.set(String(imported.path.dropFirst(supportPath.count)), forKey: "modelRelativePath")
            }
            resetView()
            savedMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func setBackground(data: Data) throws {
        // Decode at the target size, avoiding a full-resolution allocation for large photos.
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw StudioError.invalidPhoto }
        let image = UIImage(cgImage: thumbnail)
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else { throw StudioError.invalidPhoto }
        try FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try jpeg.write(to: Self.photoURL, options: .atomic)
        background = image
        savedMessage = nil
    }

    func removeBackground() {
        do {
            if FileManager.default.fileExists(atPath: Self.photoURL.path) {
                try FileManager.default.removeItem(at: Self.photoURL)
            }
            background = nil
            savedMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func resetView() { manualYaw = -0.25; manualPitch = 0; zoom = 1 }

    func savePreferences() {
        UserDefaults.standard.set(tiltEnabled, forKey: "tiltEnabled")
        UserDefaults.standard.set(sensitivity, forKey: "sensitivity")
    }

    func saveWidget() async {
        guard !isSaving, !isImporting else { return }
        isSaving = true
        defer { isSaving = false }
        // Allow SwiftUI to show progress before producing the still render.
        await Task.yield()
        do {
            let renderer = SCNRenderer(device: nil, options: nil)
            renderer.scene = scene
            renderer.pointOfView = SceneFactory.camera(in: scene)
            renderer.autoenablesDefaultLighting = false
            let size = CGSize(width: 1200, height: 1200)
            let object = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let composite = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let bounds = CGRect(origin: .zero, size: size)
                if let photo = background {
                    let ratio = max(size.width / photo.size.width, size.height / photo.size.height)
                    let target = CGSize(width: photo.size.width * ratio, height: photo.size.height * ratio)
                    photo.draw(in: CGRect(x: (size.width - target.width) / 2, y: (size.height - target.height) / 2,
                                          width: target.width, height: target.height))
                    UIColor.black.withAlphaComponent(0.16).setFill()
                    context.fill(bounds)
                } else {
                    let colors = [UIColor(red: 0.22, green: 0.23, blue: 0.32, alpha: 1).cgColor,
                                  UIColor(red: 0.09, green: 0.10, blue: 0.16, alpha: 1).cgColor]
                    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                        context.cgContext.drawLinearGradient(gradient, start: .zero,
                            end: CGPoint(x: size.width, y: size.height), options: [])
                    }
                }
                object.draw(in: bounds)
            }
            try WidgetStore.save(image: composite, modelName: modelName)
            WidgetCenter.shared.reloadAllTimelines()
            savedMessage = "View saved. Add Glean from the Home Screen widget gallery. Existing widgets refresh when iPadOS allows."
        } catch { errorMessage = error.localizedDescription }
    }
}

private enum StudioError: LocalizedError {
    case invalidPhoto
    var errorDescription: String? { "This photo couldn’t be opened. Choose another image." }
}
