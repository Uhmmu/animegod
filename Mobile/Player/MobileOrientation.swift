import Combine
import CoreMotion
import SwiftUI
import UIKit

/// Rotation, for people who keep the system's rotation lock on.
///
/// Most phones live with Orientation Lock enabled, which is fine everywhere
/// except a video player: the one place turning the phone sideways is exactly
/// what you meant. Asking people to open Control Centre, unlock, watch, and
/// lock again is not a design.
///
/// **So the phone's real posture is measured, and offered rather than
/// imposed.** When the way the phone is held disagrees with what is on
/// screen — which can only happen while rotation is locked, because otherwise
/// iOS has already turned the interface — a small button appears and takes
/// the hint. With the lock off nothing ever appears, because there is never a
/// disagreement to report. The button times out on its own, so a phone put
/// down at an angle does not leave a control sitting on the picture.
///
/// **The posture comes from the accelerometer, not from `UIDevice`.**
/// `UIDevice.current.orientation` stops tracking the device once the user
/// locks rotation — it simply keeps reporting the locked orientation — which
/// made the first version of this silently useless in the one situation it
/// exists for: held in landscape while pinned to portrait, it reported
/// portrait, so no button appeared; and after a manual rotation to landscape
/// it still reported portrait, so it offered to go back. CoreMotion reads the
/// hardware and the lock does not touch it.
///
/// `requestGeometryUpdate` likewise overrides the device lock, which is what
/// makes the button able to do anything at all.
@MainActor
final class MobileOrientation: ObservableObject {
    /// The orientation the phone is physically being held in, when that is
    /// not the one on screen and the offer has not timed out.
    @Published private(set) var suggestion: UIInterfaceOrientation?
    /// The interface's own orientation, republished so views can ask.
    @Published private(set) var current: UIInterfaceOrientation = .portrait

    /// How long an unanswered offer stays on screen.
    private static let offerTimeout: Duration = .seconds(10)
    /// How long the phone must be held still in a posture before it counts.
    private static let settle: Duration = .milliseconds(400)

    private let motion = CMMotionManager()
    /// The posture the accelerometer currently reports, whether or not it
    /// disagrees with the interface.
    private var held: UIInterfaceOrientation?
    /// A posture seen but not yet held long enough to believe.
    private var pending: (orientation: UIInterfaceOrientation, since: ContinuousClock.Instant)?
    private var offerExpiry: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    /// True once this session has rotated the interface by hand, so leaving
    /// the player knows whether it has anything to put back.
    private(set) var hasForcedOrientation = false
    /// Set while a rotation we asked for is still settling, so the offer does
    /// not flicker back on between the request and the new geometry.
    private var isApplying = false

    init() {
        current = Self.scene?.interfaceOrientation ?? .portrait
    }

    // No deinit: a nonisolated one cannot touch this state under strict
    // concurrency, and it does not need to — `stop()` is called from the
    // player's `onDisappear`.

    func start() {
        current = Self.scene?.interfaceOrientation ?? .portrait
        // `stop()` can cut a rotation's settle short, leaving the flag set.
        isApplying = false
        guard motion.isAccelerometerAvailable, !motion.isAccelerometerActive else { return }
        // 10 Hz is plenty to notice a phone being turned over, and an order
        // of magnitude cheaper than the default rate.
        motion.accelerometerUpdateInterval = 0.1
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            MainActor.assumeIsolated {
                self?.observed(Self.posture(of: data.acceleration))
            }
        }
    }

    func stop() {
        motion.stopAccelerometerUpdates()
        offerExpiry?.cancel()
        offerExpiry = nil
        settleTask?.cancel()
        settleTask = nil
        pending = nil
        held = nil
        suggestion = nil
    }

    /// Takes the phone's own orientation.
    func takeSuggestion() {
        guard let suggestion else { return }
        rotate(to: suggestion)
    }

    /// Flips between portrait and landscape by hand, for when the phone is
    /// lying flat and the accelerometer has nothing to say.
    func toggle() {
        rotate(to: current.isPortrait ? (held ?? .landscapeRight) : .portrait)
    }

    /// Puts the interface back the way it was found, if this session moved
    /// it. Leaving a player in landscape must not leave the library sideways
    /// — but a phone that rotated on its own, with the lock off, was never
    /// ours to put back.
    func restoreIfForced() {
        guard hasForcedOrientation else { return }
        rotate(to: .portrait, isUserChoice: false)
    }

    func rotate(to orientation: UIInterfaceOrientation, isUserChoice: Bool = true) {
        guard let scene = Self.scene else { return }
        if isUserChoice { hasForcedOrientation = true }
        isApplying = true
        clearOffer()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation.mask)) { _ in }
        // The window scene reports its new orientation a beat after the
        // request.
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.isApplying = false
            self.current = Self.scene?.interfaceOrientation ?? orientation
            self.reconsider()
        }
    }

    // MARK: - Posture

    private func observed(_ posture: UIInterfaceOrientation?) {
        guard let posture else {
            // Flat on a table: no opinion, and an offer already made stands
            // until it times out rather than vanishing under the finger.
            pending = nil
            return
        }
        guard posture != held else {
            pending = nil
            return
        }
        let now = ContinuousClock.now
        if let pending, pending.orientation == posture {
            guard now - pending.since >= Self.settle else { return }
            self.pending = nil
            held = posture
            reconsider()
        } else {
            pending = (posture, now)
        }
    }

    /// Offers the held posture if it disagrees with what is on screen.
    private func reconsider() {
        guard !isApplying else { return }
        let interface = Self.scene?.interfaceOrientation ?? current
        current = interface
        guard let held, held != interface else {
            clearOffer()
            return
        }
        suggestion = held
        offerExpiry?.cancel()
        offerExpiry = Task { [weak self] in
            try? await Task.sleep(for: Self.offerTimeout)
            guard !Task.isCancelled else { return }
            self?.suggestion = nil
        }
    }

    private func clearOffer() {
        offerExpiry?.cancel()
        offerExpiry = nil
        suggestion = nil
    }

    /// The interface orientation a gravity reading corresponds to.
    ///
    /// At rest the accelerometer reports the **down** direction in device
    /// coordinates, where `+x` is the device's right edge and `+y` its top.
    /// `.landscapeRight` means the device's bottom edge points right, so its
    /// right edge points up and down reads as `-x`; `.landscapeLeft` is the
    /// mirror. Deriving it this way rather than copying `UIDeviceOrientation`
    /// case names avoids the trap that those two enumerations are mirrored,
    /// which gives a button that rotates the wrong way.
    private static func posture(of g: CMAcceleration) -> UIInterfaceOrientation? {
        // Face up or face down: gravity is along the screen normal and the
        // in-plane components are noise.
        guard abs(g.z) < 0.8 else { return nil }
        let threshold = 0.6
        if abs(g.y) > abs(g.x) {
            // Upside down is not offered: Info.plist does not list it, so the
            // request would be refused and the button would do nothing.
            return g.y < -threshold ? .portrait : nil
        }
        if g.x < -threshold { return .landscapeRight }
        if g.x > threshold { return .landscapeLeft }
        return nil
    }

    private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

extension UIInterfaceOrientation {
    var mask: UIInterfaceOrientationMask {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .portrait
        }
    }
}
