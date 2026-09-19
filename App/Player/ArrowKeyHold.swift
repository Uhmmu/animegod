import AppKit

/// ← / → in the player: a tap seeks 10 s; holding scans at 2×; a tap
/// followed quickly by a hold scans at 3×. SwiftUI keyboard shortcuts only
/// see key-down (and auto-repeat), so this watches key-down and key-up
/// through a local event monitor, limited to the player window.
///
/// The tap acts on key-up, since only then is it known not to be a hold.
@MainActor
final class ArrowKeyHold {
    enum Direction { case back, forward }

    /// How long a key must stay down to count as a hold.
    private static let holdDelay: Duration = .milliseconds(300)
    /// A hold starting this soon after a tap on the same key scans at 3×.
    private static let doubleTapWindow: TimeInterval = 0.35

    private var monitor: Any?
    private var window: () -> NSWindow? = { nil }
    private var isSuspended: () -> Bool = { false }
    private var tap: (Direction) -> Void = { _ in }
    private var beginHold: (Direction, Double) -> Void = { _, _ in }
    private var endHold: () -> Void = {}

    private var pressed: Direction?
    private var holding = false
    private var holdTask: Task<Void, Never>?
    private var lastTap: (direction: Direction, at: Date)?

    func install(
        window: @escaping () -> NSWindow?,
        isSuspended: @escaping () -> Bool,
        tap: @escaping (Direction) -> Void,
        beginHold: @escaping (Direction, Double) -> Void,
        endHold: @escaping () -> Void
    ) {
        uninstall()
        self.window = window
        self.isSuspended = isSuspended
        self.tap = tap
        self.beginHold = beginHold
        self.endHold = endHold
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    func uninstall() {
        cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Forgets a key that is down, e.g. when the app loses focus and its
    /// key-up would go elsewhere. Ending the hold itself is the caller's.
    func cancel() {
        holdTask?.cancel()
        holdTask = nil
        pressed = nil
        holding = false
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let direction: Direction
        switch event.keyCode {
        case 123: direction = .back
        case 124: direction = .forward
        default: return false
        }
        guard event.window != nil, event.window === window(),
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !isSuspended() else { return false }

        if event.type == .keyDown {
            // Auto-repeat while held: the hold timer already decides.
            guard !event.isARepeat, pressed == nil else { return true }
            pressed = direction
            let rate: Double = if let lastTap, lastTap.direction == direction,
                                  Date().timeIntervalSince(lastTap.at) < Self.doubleTapWindow { 3 } else { 2 }
            holdTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.holdDelay)
                guard let self, !Task.isCancelled, self.pressed == direction else { return }
                self.holding = true
                self.beginHold(direction, rate)
            }
            return true
        }

        guard pressed == direction else { return true }
        holdTask?.cancel()
        holdTask = nil
        if holding {
            endHold()
            lastTap = nil
        } else {
            tap(direction)
            lastTap = (direction, Date())
        }
        pressed = nil
        holding = false
        return true
    }
}
