// Watches the system for what the pacer weighs: whether the window can be seen,
// the screen locked or asleep, power, heat, Reduce Motion and how long the user
// has been away. Every source is a public notification or query, so it needs no
// entitlements or permissions. Everything is delivered on the main thread and
// written straight into the pacer's signals.

import AppKit
import CoreGraphics
import IOKit.ps

/// Keeps a ``RenderPacer``'s system signals current. It writes only the system's fields, never
/// `explicitlyPaused`, `characterAtRest` or `speaking`, which belong to the view.
@MainActor
public final class SystemSignals {
    /// The pacer whose signals are kept current.
    public let pacer: RenderPacer
    /// How often user idle time is read, in seconds, while the user is active.
    public let idleSampleInterval: TimeInterval
    /// The window whose occlusion is followed, if any.
    public private(set) weak var window: NSWindow?
    /// Whether it is observing the system.
    public private(set) var isRunning = false

    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var windowObservers: [any NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var idleTimer: Timer?
    private var locked = false
    private var sessionInactive = false

    /// Signals for `pacer`. Call ``start()`` to begin observing.
    public init(pacer: RenderPacer, idleSampleInterval: TimeInterval = 5) {
        self.pacer = pacer
        self.idleSampleInterval = idleSampleInterval
    }

    isolated deinit {
        stop()
        detach()
    }

    /// Read every signal now and follow its changes until ``stop()``.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, "com.apple.screenIsLocked") { $0.locked = true; $0.updateLock() }
        observe(distributed, "com.apple.screenIsUnlocked") { $0.locked = false; $0.updateLock() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true; $0.updateLock() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false; $0.updateLock() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.pacer.signals.displayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.pacer.signals.displayAsleep = false }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.pacer.signals.systemSleeping = true }
        observe(workspace, NSWorkspace.didWakeNotification) {
            $0.pacer.signals.systemSleeping = false
            $0.sampleIdle()
        }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { $0.readReduceMotion() }
        observe(.default, .NSProcessInfoPowerStateDidChange) { $0.readPowerMode() }
        observe(.default, ProcessInfo.thermalStateDidChangeNotification) { $0.readThermal() }

        // IOKit calls back on the run loop it is added to: the main one.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<SystemSignals>.fromOpaque(context).takeUnretainedValue().readBattery()
            }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }

        locked = Self.sessionIsLocked()
        updateLock()
        pacer.signals.displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        readReduceMotion()
        readPowerMode()
        readThermal()
        readBattery()
        readOcclusion()
        sampleIdle()
    }

    /// Stop observing the system. The signals keep their last values; window observation stays until ``detach()``.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// Follow `window`'s occlusion instead of any window before it; nil detaches. Call it whenever the view's window changes.
    public func attach(window: NSWindow?) {
        if let window, window === self.window { return }
        detach()
        guard let window else { return }
        self.window = window
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readOcclusion() }
            },
            // A closed window is unseen until it is shown again, which its occlusion change reports.
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pacer.signals.occluded = true }
            },
        ]
        readOcclusion()
    }

    /// Stop following the window. Without a window the character counts as visible.
    public func detach() {
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        windowObservers.removeAll()
        window = nil
        pacer.signals.occluded = false
    }

    // MARK: Reading

    private func observe(_ center: NotificationCenter, _ name: String, _ body: @escaping @MainActor (SystemSignals) -> Void) {
        observe(center, Notification.Name(name), body)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (SystemSignals) -> Void) {
        // queue: .main delivers on the main thread whichever thread posted it.
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { body(self) }
            }
        }
        observers.append((center, token))
    }

    private func updateLock() {
        pacer.signals.screenLocked = locked || sessionInactive
    }

    private func readOcclusion() {
        guard let window else { return }
        pacer.signals.occluded = !window.occlusionState.contains(.visible)
    }

    private func readReduceMotion() {
        pacer.signals.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func readPowerMode() {
        pacer.signals.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func readThermal() {
        pacer.signals.thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
    }

    private func readBattery() {
        pacer.signals.onBattery = Self.providingPowerSource() == kIOPSBatteryPowerValue
    }

    /// Reads idle time, then schedules the next read: every second once idle starts to matter, so
    /// the character wakes promptly when the user comes back, and every `idleSampleInterval` otherwise.
    private func sampleIdle() {
        guard isRunning else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        pacer.signals.userIdleSeconds = idle
        let interval = idle >= pacer.policy.relaxAfterIdle ? min(1, idleSampleInterval) : idleSampleInterval
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleIdle() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private static func providingPowerSource() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    }

    /// Whether the session is locked now; the lock notifications only say when it changes.
    private static func sessionIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
