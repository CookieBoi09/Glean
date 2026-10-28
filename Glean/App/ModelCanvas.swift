import SwiftUI
import SceneKit

struct ModelCanvas: UIViewRepresentable {
    @ObservedObject var studio: StudioModel
    var motionYaw: Double
    var motionPitch: Double

    func makeCoordinator() -> Coordinator { Coordinator(studio: studio) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.autoenablesDefaultLighting = false
        view.allowsCameraControl = false
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:))))
        view.accessibilityLabel = "Interactive 3D model"
        view.accessibilityHint = "Drag to rotate or pinch to zoom. Use the controls below for accessible rotation."
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if view.scene !== studio.scene {
            view.scene = studio.scene
            view.pointOfView = SceneFactory.camera(in: studio.scene)
        }
        let yaw = studio.manualYaw + (studio.tiltEnabled ? motionYaw * studio.sensitivity : 0)
        let pitch = studio.manualPitch + (studio.tiltEnabled ? motionPitch * studio.sensitivity : 0)
        let content = SceneFactory.content(in: studio.scene)
        content.eulerAngles = SCNVector3(Float(pitch), Float(yaw), 0)
        // SceneFactory uses a perspective camera, so orthographicScale has no effect.
        view.pointOfView?.camera?.fieldOfView = CGFloat(36 / studio.zoom)
        view.setNeedsDisplay()
    }

    @MainActor
    final class Coordinator: NSObject {
        let studio: StudioModel
        init(studio: StudioModel) { self.studio = studio }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            let delta = gesture.translation(in: gesture.view)
            studio.manualYaw += delta.x * 0.008
            studio.manualPitch = min(1.2, max(-1.2, studio.manualPitch + delta.y * 0.008))
            gesture.setTranslation(.zero, in: gesture.view)
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            studio.zoom = min(1.5, max(0.6, studio.zoom * gesture.scale))
            gesture.scale = 1
        }
    }
}
