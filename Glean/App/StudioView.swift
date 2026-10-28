import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private enum StudioTheme {
    static let background = Color(red: 0.055, green: 0.060, blue: 0.085)
    static let panel = Color(red: 0.095, green: 0.10, blue: 0.135)
    static let accent = Color(red: 0.73, green: 0.66, blue: 1)
    static let muted = Color(red: 0.60, green: 0.62, blue: 0.69)
}

private enum PreviewSize: String, CaseIterable, Identifiable {
    case small = "Small", medium = "Medium", large = "Large"
    var id: String { rawValue }
    var ratio: CGFloat { self == .medium ? 2.12 : 1 }
}

struct StudioView: View {
    @StateObject private var studio = StudioModel()
    @StateObject private var motion = MotionController()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showImporter = false
    @State private var photoItem: PhotosPickerItem?
    @State private var previewSize: PreviewSize = .large
    @State private var showHelp = false
    @State private var loadingPhoto = false
    @State private var photoTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if geometry.size.width >= 900 {
                        HStack(alignment: .top, spacing: 36) {
                            preview.frame(maxWidth: .infinity)
                            controls.frame(width: 310)
                        }
                    } else {
                        preview
                        controls
                    }
                    footer
                }
                .padding(geometry.size.width >= 900 ? 40 : 22)
                .frame(maxWidth: 1440)
                .frame(maxWidth: .infinity)
            }
            .background(StudioTheme.background)
        }
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .onAppear { updateMotion() }
        .onChange(of: scenePhase) { _, _ in updateMotion() }
        .onChange(of: studio.tiltEnabled) { _, _ in studio.savePreferences(); updateMotion() }
        .onChange(of: studio.sensitivity) { _, _ in studio.savePreferences() }
        .onDisappear { motion.stop(); photoTask?.cancel() }
        .onOpenURL { url in
            if url.scheme == "glean" { updateMotion() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .folder]) { result in
            switch result {
            case .success(let url): Task { await studio.importModel(url) }
            case .failure(let error): studio.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: photoItem) { _, item in
            photoTask?.cancel()
            guard let item else { return }
            photoTask = Task { @MainActor in
                loadingPhoto = true
                defer { if !Task.isCancelled { loadingPhoto = false } }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    try Task.checkCancellation()
                    try studio.setBackground(data: data)
                } catch is CancellationError { }
                catch { studio.errorMessage = "Couldn’t load this photo. \(error.localizedDescription)" }
            }
        }
        .alert("Something needs attention", isPresented: Binding(
            get: { studio.errorMessage != nil },
            set: { if !$0 { studio.errorMessage = nil } }
        ), actions: { Button("OK", role: .cancel) { studio.errorMessage = nil } },
        message: { Text(studio.errorMessage ?? "") })
        .sheet(isPresented: $showHelp) { help }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 12) {
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(StudioTheme.accent)
                    .accessibilityHidden(true)
                Text("glean").font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1.5)
            }
            Spacer()
            if horizontalSizeClass == .regular {
                Text("YOUR LITTLE WORLD")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(StudioTheme.muted)
                    .accessibilityHidden(true)
            }
            Button { showHelp = true } label: {
                Image(systemName: "questionmark.circle").font(.title3).padding(10)
            }.accessibilityLabel("How Glean works")
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("A new dimension\nfor your Home Screen.")
                    .font(.system(size: 38, weight: .medium, design: .rounded))
                    .tracking(-1.2).fixedSize(horizontal: false, vertical: true)
                Text("Pick a model. Make it yours. Give it a little tilt.")
                    .font(.subheadline).foregroundStyle(StudioTheme.muted)
            }
            HStack {
                Label("STUDIO", systemImage: "circle.fill")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(StudioTheme.accent)
                Spacer()
                HStack(spacing: 4) {
                    ForEach(PreviewSize.allCases) { size in
                        Button { withAnimation(.easeInOut(duration: 0.25)) { previewSize = size } } label: {
                            Text(size.rawValue).font(.caption.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(previewSize == size ? Color.white.opacity(0.12) : .clear, in: Capsule())
                        }
                        .foregroundStyle(previewSize == size ? .white : StudioTheme.muted)
                        .accessibilityAddTraits(previewSize == size ? .isSelected : [])
                    }
                }.padding(4).background(StudioTheme.panel, in: Capsule())
            }
            ZStack {
                RoundedRectangle(cornerRadius: 36)
                    .fill(StudioTheme.panel.opacity(0.35))
                VStack(spacing: 20) {
                    ZStack(alignment: .bottomLeading) {
                        background
                        GeometryReader { proxy in
                            ModelCanvas(studio: studio, motionYaw: motion.yaw, motionPitch: motion.pitch)
                                .frame(width: min(proxy.size.width, proxy.size.height), height: min(proxy.size.width, proxy.size.height))
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(studio.modelName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("GLEAN / 01").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2).opacity(0.6)
                        }.padding(20).allowsHitTesting(false)
                    }
                    .aspectRatio(previewSize.ratio, contentMode: .fit)
                    .frame(maxWidth: previewSize == .small ? 240 : previewSize == .medium ? 560 : 420)
                    .clipShape(RoundedRectangle(cornerRadius: previewSize == .small ? 28 : 34))
                    .overlay(RoundedRectangle(cornerRadius: previewSize == .small ? 28 : 34).strokeBorder(.white.opacity(0.1)))
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 16)
                    Label(studio.tiltEnabled ? (motion.isActive ? "Tilt your iPad · drag to explore" : motion.status) : "Drag to rotate · pinch to zoom", systemImage: "hand.draw")
                        .font(.caption).foregroundStyle(StudioTheme.muted)
                }.padding(28)
                if studio.isImporting {
                    RoundedRectangle(cornerRadius: 36).fill(.black.opacity(0.6))
                    ProgressView("Opening your model…").padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .frame(minHeight: previewSize == .large ? 500 : 330)
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text("Tilt is live in the app. Widgets display your saved view.")
            }.font(.caption).foregroundStyle(StudioTheme.muted)
        }
    }

    private var background: some View {
        GeometryReader { proxy in
            if let image = studio.background {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    .overlay(.black.opacity(0.16))
            } else {
                LinearGradient(colors: [Color(red: 0.22, green: 0.23, blue: 0.32), Color(red: 0.09, green: 0.10, blue: 0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }.allowsHitTesting(false)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionLabel("01", "The object")
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "cube.fill").font(.title2).foregroundStyle(StudioTheme.accent)
                        .frame(width: 48, height: 48).background(StudioTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(studio.modelName).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(studio.usingDefault ? "Among Us–style test model" : "Imported from Files")
                            .font(.caption).foregroundStyle(StudioTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
                if studio.usingDefault {
                    HStack(spacing: 14) {
                        ForEach(StudioModel.palette.indices, id: \.self) { index in
                            Button { studio.setColor(index) } label: {
                                Circle().fill(Color(uiColor: StudioModel.palette[index]))
                                    .frame(width: 28, height: 28)
                                    .padding(5)
                                    .overlay(Circle().strokeBorder(studio.selectedColor == index ? .white : .clear, lineWidth: 1.5))
                            }
                            .accessibilityLabel(StudioModel.colorNames[index])
                            .accessibilityAddTraits(studio.selectedColor == index ? .isSelected : [])
                        }
                    }
                }
                Button { showImporter = true } label: {
                    Label("Import a 3D model", systemImage: "plus").frame(maxWidth: .infinity)
                }.buttonStyle(SecondaryButton()).disabled(studio.isImporting)
                Text("USDZ, USD, OBJ, GLB, glTF & more. Select a folder for models with separate textures.")
                    .font(.caption2).foregroundStyle(StudioTheme.muted).fixedSize(horizontal: false, vertical: true)
                if !studio.usingDefault {
                    Button("Use test model") { studio.useDefault() }.font(.caption)
                }
            }.panel()

            sectionLabel("02", "The atmosphere")
            VStack(alignment: .leading, spacing: 14) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12).fill(StudioTheme.accent.opacity(0.12))
                            if let image = studio.background {
                                Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipped()
                            } else { Image(systemName: "photo.on.rectangle.angled").foregroundStyle(StudioTheme.accent) }
                        }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loadingPhoto ? "Loading photo…" : "Choose a photo").font(.subheadline.weight(.medium))
                            Text("Your backdrop, your world").font(.caption).foregroundStyle(StudioTheme.muted)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                }.buttonStyle(.plain)
                if studio.background != nil {
                    Button("Restore studio background") {
                        photoTask?.cancel(); photoItem = nil; loadingPhoto = false
                        studio.removeBackground()
                    }.font(.caption)
                }
            }.panel()

            sectionLabel("03", "The movement")
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $studio.tiltEnabled) {
                    Label("Follow my iPad", systemImage: "gyroscope").font(.subheadline)
                }
                if studio.tiltEnabled {
                    HStack {
                        Text("Sensitivity").font(.caption).foregroundStyle(StudioTheme.muted)
                        Slider(value: $studio.sensitivity, in: 0.3...2.5).accessibilityLabel("Tilt sensitivity")
                    }
                    Text(motion.isAvailable ? "Hold your iPad comfortably, then recenter." : "Motion isn’t available on this device. Use drag or the rotation controls.")
                        .font(.caption2).foregroundStyle(StudioTheme.muted)
                }
                DisclosureGroup("Touch & accessible controls") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Horizontal rotation").font(.caption)
                        Slider(value: $studio.manualYaw, in: -Double.pi...Double.pi).accessibilityLabel("Horizontal rotation")
                        Text("Vertical rotation").font(.caption)
                        Slider(value: $studio.manualPitch, in: -1.2...1.2).accessibilityLabel("Vertical rotation")
                        Text("Zoom").font(.caption)
                        Slider(value: $studio.zoom, in: 0.6...1.5).accessibilityLabel("Model zoom")
                    }.padding(.top, 10)
                }.font(.caption).foregroundStyle(StudioTheme.muted)
                Button {
                    studio.resetView(); motion.resetReference()
                } label: { Label("Recenter model", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity) }
                .buttonStyle(SecondaryButton())
            }.panel()

            Button {
                Task { await studio.saveWidget() }
            } label: {
                HStack(spacing: 10) {
                    if studio.isSaving { ProgressView().tint(StudioTheme.background) }
                    else { Image(systemName: "square.grid.2x2") }
                    Text(studio.isSaving ? "Saving your view…" : "Save to widgets").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }.padding(18).foregroundStyle(StudioTheme.background)
                    .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 18))
            }.buttonStyle(.plain).disabled(studio.isSaving || studio.isImporting || loadingPhoto)
            if let message = studio.savedMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(StudioTheme.accent).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .top) {
            Text("A little space for something you love.").font(.caption).foregroundStyle(StudioTheme.muted)
            Spacer()
            Text("MADE TO MOVE").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2).foregroundStyle(StudioTheme.muted)
        }.padding(.top, 8)
    }

    private func sectionLabel(_ number: String, _ name: String) -> some View {
        HStack(spacing: 10) {
            Text(number).font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioTheme.accent)
            Text(name).font(.subheadline.weight(.semibold))
        }
    }

    private func updateMotion() {
        if scenePhase == .active && studio.tiltEnabled { motion.start() } else { motion.stop() }
    }

    private var help: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "cube.transparent.fill").font(.system(size: 52)).foregroundStyle(StudioTheme.accent)
                    Text("Your model.\nA whole new angle.").font(.largeTitle.weight(.semibold))
                    Text("Tilt your iPad to look around your model, or drag and pinch. Choose a photo to make the scene your own.")
                    Text("On your Home Screen").font(.headline)
                    Text("Tap Save to widgets, then touch and hold your Home Screen, open the widget gallery, and choose Glean. Small, medium, and large widgets show your last saved view. Tap one to return here. Apple does not allow widgets to read live device motion or run an interactive 3D renderer.")
                    Text("Bring your own object").font(.headline)
                    Text("Import USDZ, USD, USDA, USDC, SCN, DAE, OBJ, STL, PLY, GLB, or glTF. Native format availability depends on iPadOS. For a model with separate textures or buffers, select its containing folder. GLB/glTF support static, uncompressed triangle meshes; skeletal animation, morph targets, and compressed extensions are not supported. Convert FBX or Blender projects to USDZ or GLB first.")
                    Text("Your photos and models stay on this device. The bundled crewmate is an original procedural test asset inspired by Among Us, not an official game asset.")
                        .font(.footnote).foregroundStyle(StudioTheme.muted)
                }.padding(28)
            }.background(StudioTheme.background)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } } }
        }.preferredColorScheme(.dark)
    }
}

private struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption.weight(.medium))
            .padding(.vertical, 12).padding(.horizontal, 14)
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 0.9))
            .background(.white.opacity(configuration.isPressed ? 0.10 : 0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }
}

private extension View {
    func panel() -> some View {
        padding(18).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 20))
    }
}
