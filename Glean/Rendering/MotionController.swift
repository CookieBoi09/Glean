import Combine
import CoreMotion
import Foundation
import UIKit

/// Relative motion keeps the pose neutral when motion is enabled or recentered.
@MainActor
final class MotionController: ObservableObject {
    @Published private(set) var yaw: Double = 0
    @Published private(set) var pitch: Double = 0
    @Published private(set) var isActive = false
    @Published private(set) var status: String = "Tilt to explore"

    var isAvailable: Bool { manager.isDeviceMotionAvailable }
    private let manager = CMMotionManager()
    private var reference: CMAttitude?
    private var orientation: UIDeviceOrientation = .portrait

    func start() {
        guard !isActive else { return }
        guard manager.isDeviceMotionAvailable else {
            status = "Motion is unavailable here. Drag the model to rotate."
            return
        }
        reference = nil
        yaw = 0
        pitch = 0
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        if UIDevice.current.orientation.isValidInterfaceOrientation {
            orientation = UIDevice.current.orientation
        }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, error in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                if error != nil {
                    self.stop()
                    self.status = "Motion stopped. You can still drag to rotate."
                    return
                }
                guard let motion else { return }
                self.consume(motion)
            }
        }
        isActive = true
        status = "Tilt to explore"
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        if isActive { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        isActive = false
        reference = nil
        yaw = 0
        pitch = 0
    }

    func resetReference() {
        reference = nil
        yaw = 0
        pitch = 0
    }

    private func consume(_ motion: CMDeviceMotion) {
        let currentOrientation = UIDevice.current.orientation
        if currentOrientation.isValidInterfaceOrientation, currentOrientation != orientation {
            orientation = currentOrientation
            resetReference()
        }
        guard let reference else {
            self.reference = motion.attitude.copy() as? CMAttitude
            return
        }
        guard let relative = motion.attitude.copy() as? CMAttitude else { return }
        relative.multiply(byInverseOf: reference)
        var horizontal = relative.roll
        var vertical = relative.pitch
        switch orientation {
        case .landscapeLeft:
            horizontal = -relative.pitch
            vertical = relative.roll
        case .landscapeRight:
            horizontal = relative.pitch
            vertical = -relative.roll
        case .portraitUpsideDown:
            horizontal = -relative.roll
            vertical = -relative.pitch
        default:
            break
        }
        // A little amplification makes small tilts useful; smoothing avoids sensor jitter.
        let targetYaw = max(-1.3, min(1.3, horizontal * 1.7 + relative.yaw * 0.35))
        let targetPitch = max(-0.8, min(0.8, vertical * 1.4))
        yaw += (targetYaw - yaw) * 0.18
        pitch += (targetPitch - pitch) * 0.18
    }
}
