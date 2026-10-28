import Foundation
import ModelIO

/// Copies imports into app-owned storage before the Files security scope expires.
enum ModelImporter {
    static var supportedExtensions: [String] {
        let native = ["obj", "ply", "stl", "abc"]
            .filter { MDLAsset.canImportFileExtension($0) }
        return ["usdz", "usd", "usda", "usdc", "scn", "dae", "gltf", "glb"] + native
    }

    enum ImportError: LocalizedError {
        case tooLarge
        case tooManyFiles
        case symbolicLink
        case unsupported
        case ambiguousFolder
        case folderRequired
        case unreadable

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "Choose a model smaller than 100 MB, or a model folder smaller than 200 MB."
            case .tooManyFiles: return "This folder contains more than 512 files. Choose a folder containing only the model and its textures."
            case .symbolicLink: return "Model folders cannot contain symbolic links. Copy the actual model and texture files into a folder first."
            case .unsupported: return "This file type is not supported. Try USDZ, GLB, glTF, OBJ, or a SceneKit scene."
            case .ambiguousFolder: return "Select a folder with exactly one model at its top level. Keep its buffers, materials, and textures inside that folder."
            case .folderRequired: return "This OBJ references a material file. Import its folder to include the MTL file and textures, or export a self-contained USDZ or GLB."
            case .unreadable: return "The selected model could not be read. Download it in Files first and try again."
            }
        }
    }

    static func importModel(from source: URL) throws -> URL {
        let hasAccess = source.startAccessingSecurityScopedResource()
        defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw ImportError.symbolicLink }
        let fileManager = FileManager.default
        let models = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Glean/Models", isDirectory: true)
        try fileManager.createDirectory(at: models, withIntermediateDirectories: true)
        let destination = models.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let modelURL: URL
            if values.isDirectory == true {
                let files = try validateFolder(source)
                let candidates = files.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
                let topLevel = candidates.filter { $0.deletingLastPathComponent().standardizedFileURL == source.standardizedFileURL }
                let selected = topLevel.isEmpty ? candidates : topLevel
                guard selected.count == 1, let selectedModel = selected.first else { throw ImportError.ambiguousFolder }
                let copiedFolder = destination.appendingPathComponent("Asset", isDirectory: true)
                try fileManager.copyItem(at: source, to: copiedFolder)
                let prefix = source.standardizedFileURL.path + "/"
                guard selectedModel.standardizedFileURL.path.hasPrefix(prefix) else { throw ImportError.unreadable }
                let relativePath = String(selectedModel.standardizedFileURL.path.dropFirst(prefix.count))
                modelURL = copiedFolder.appendingPathComponent(relativePath)
            } else {
                guard supportedExtensions.contains(source.pathExtension.lowercased()) else { throw ImportError.unsupported }
                guard let size = values.fileSize, size > 0 else { throw ImportError.unreadable }
                guard size <= 100 * 1_024 * 1_024 else { throw ImportError.tooLarge }
                if source.pathExtension.lowercased() == "obj" {
                    let text = try String(contentsOf: source, encoding: .utf8)
                    if text.split(whereSeparator: \.isNewline).contains(where: {
                        $0.split(whereSeparator: \.isWhitespace).first == "mtllib"
                    }) {
                        throw ImportError.folderRequired
                    }
                }
                modelURL = destination.appendingPathComponent(source.lastPathComponent)
                try fileManager.copyItem(at: source, to: modelURL)
            }
            // The previous selection remains valid if parsing or rendering this import fails.
            _ = try SceneFactory.makeScene(modelURL: modelURL)
            return modelURL
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private static func validateFolder(_ folder: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else { throw ImportError.unreadable }
        var files: [URL] = []
        var totalBytes = 0
        var entries = 0
        for case let file as URL in enumerator {
            entries += 1
            guard entries <= 1_024 else { throw ImportError.tooManyFiles }
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw ImportError.symbolicLink }
            if values.isRegularFile == true {
                guard let size = values.fileSize else { throw ImportError.unreadable }
                totalBytes += size
                guard totalBytes <= 200 * 1_024 * 1_024 else { throw ImportError.tooLarge }
                if supportedExtensions.contains(file.pathExtension.lowercased()), size > 100 * 1_024 * 1_024 {
                    throw ImportError.tooLarge
                }
                files.append(file)
                guard files.count <= 512 else { throw ImportError.tooManyFiles }
            }
        }
        if let traversalError { throw traversalError }
        return files
    }
}
