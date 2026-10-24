import AppKit
import MetalKit
import QuartzCore
import Synchronization

/// A transparent Metal view that shows one character and keeps it alive: it advances and draws it
/// on a display link paced by a ``RenderPacer``, follows the pointer, turns clicks into
/// ``CharacterRenderer/poke()``, and answers whether a point is on the character, for a
/// click-through panel.
///
/// The character is laid out to fit the view: the largest resting box whose canvas fits the bounds,
/// centred, unless ``preferredBox`` fixes it. Use ``canvasSize(for:box:)`` to size a window so a
/// box of a given size fits exactly.
@MainActor
public final class CharacterView: MTKView {
    public let character: any CharacterRenderer
    public let pacer: RenderPacer
    /// The system signals feeding ``pacer``: occlusion, lock, power, thermal, Reduce Motion, idle.
    public let systemSignals: SystemSignals
    /// Timings of recent frames, readable from any thread.
    public let stats = FrameStats()

    /// Follow the pointer and react to clicks. Default true.
    public var isInteractive = true
    /// Called for a click on the character (after it has been poked).
    public var onClick: ((NSEvent) -> Void)?
    /// A fixed resting box in points; nil fits the character to the bounds.
    public var preferredBox: CGFloat? { didSet { requestFrame() } }
    /// Keep the window click-through except over the character's silhouette, by polling the mouse
    /// and toggling `ignoresMouseEvents`. For a borderless floating panel. Default false.
    public var managesWindowClickThrough = false { didSet { updateClickThroughTimer() } }
    /// Extra reach round the silhouette for ``containsCharacter(at:)``, in points.
    public var hitSlop: CGFloat = 2
    /// Whether the character's pipelines are ready; it draws nothing before.
    public private(set) var isReady = false
    /// Set when `prepare` failed.
    public private(set) var preparationError: (any Error)?

    private let queue: (any MTLCommandQueue)?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    /// Logical time for actions while nothing is drawn (occluded, locked).
    private var hiddenTicker: Timer?
    private var hiddenLast: CFTimeInterval = 0
    private var clickThroughTimer: Timer?
    private var lastMouse: NSPoint?
    private var framingCache: (size: CGSize, box: CGFloat?, framing: CharacterFraming)?
    /// The character drew its current look; nothing needs drawing until it changes or moves.
    private var drawnStill = false

    public init(character: any CharacterRenderer, device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(), policy: PacingPolicy = .standard) {
        self.character = character
        pacer = RenderPacer(policy: policy)
        systemSignals = SystemSignals(pacer: pacer)
        queue = device?.makeCommandQueue()
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibilityLabel()

        character.onChange = { [weak self] in
            self?.drawnStill = false
            self?.updateAccessibilityLabel()
            self?.requestFrame()
        }
        pacer.onBudgetChange = { [weak self] _ in self?.applyBudget() }
        if let device {
            Task { [weak self] in
                do {
                    try await character.prepare(device: device)
                    self?.isReady = true
                } catch {
                    self?.preparationError = error
                }
                self?.requestFrame()
            }
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The canvas a resting box of `box` points needs, to size a window or panel round it.
    public static func canvasSize(for character: any CharacterRenderer, box: CGFloat) -> CGSize {
        character.framing(forBox: box).canvasSize
    }

    // MARK: Layout

    /// Where the character sits in the view's bounds, y down.
    public var framing: CharacterFraming {
        let size = bounds.size
        if let c = framingCache, c.size == size, c.box == preferredBox { return c.framing }
        let box = preferredBox ?? fittingBox(in: size)
        let f = character.framing(forBox: box)
        let offset = CGPoint(x: (size.width - f.canvasSize.width) / 2, y: (size.height - f.canvasSize.height) / 2)
        let framing = CharacterFraming(box: box, canvasSize: size, boxOrigin: CGPoint(x: offset.x + f.boxOrigin.x, y: offset.y + f.boxOrigin.y))
        framingCache = (size, preferredBox, framing)
        return framing
    }

    private func fittingBox(in size: CGSize) -> CGFloat {
        guard size.width > 1, size.height > 1 else { return 1 }
        func fits(_ box: CGFloat) -> Bool {
            let c = character.framing(forBox: box).canvasSize
            return c.width <= size.width && c.height <= size.height
        }
        var lo: CGFloat = 1, hi = max(size.width, size.height)
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return fits(lo.rounded(.up)) ? lo.rounded(.up) : lo.rounded(.down)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        requestFrame()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        requestFrame()
    }

    // MARK: Hit-testing

    /// Whether a point in the view's coordinates is on the character (within ``hitSlop``).
    public func containsCharacter(at point: NSPoint) -> Bool {
        let p = canvasPoint(point)
        if character.hitTest(p, framing: framing) { return true }
        guard hitSlop > 0 else { return false }
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] where character.hitTest(CGPoint(x: p.x + dx * hitSlop, y: p.y + dy * hitSlop), framing: framing) {
            return true
        }
        return false
    }

    /// Whether a point in global screen coordinates is on the character.
    public func containsCharacter(atScreenPoint point: NSPoint) -> Bool {
        guard let window else { return false }
        return containsCharacter(at: convert(window.convertPoint(fromScreen: point), from: nil))
    }

    /// Only the character's silhouette takes clicks; the rest of the view passes them on.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive, let superview else { return nil }
        return containsCharacter(at: convert(point, from: superview)) ? self : nil
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        guard isInteractive, containsCharacter(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        character.poke()
        requestFrame()
        onClick?(event)
    }

    /// View coordinates (y up) → canvas points (y down).
    private func canvasPoint(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
    }

    private func updateClickThroughTimer() {
        clickThroughTimer?.invalidate()
        clickThroughTimer = nil
        guard managesWindowClickThrough else {
            window?.ignoresMouseEvents = false
            return
        }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        clickThroughTimer = timer
        updateClickThrough()
    }

    private func updateClickThrough() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if mouse == lastMouse && link?.isPaused != false { return }
        lastMouse = mouse
        let ignore = !(isInteractive && containsCharacter(atScreenPoint: mouse))
        if window.ignoresMouseEvents != ignore { window.ignoresMouseEvents = ignore }
    }

    // MARK: Window and pacing

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            systemSignals.attach(window: window)
            systemSignals.start()
            startLink()
            updateClickThroughTimer()
        } else {
            systemSignals.detach()
            systemSignals.stop()
            link?.invalidate()
            link = nil
            clickThroughTimer?.invalidate()
            clickThroughTimer = nil
            stopHiddenTicker()
        }
        requestFrame()
    }

    private func startLink() {
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        applyBudget()
    }

    /// Draw at least one more frame, soon: after a change, or to notice motion.
    public func requestFrame() {
        drawnStill = false
        guard window != nil else { return }
        link?.isPaused = false
    }

    private func applyBudget() {
        guard let link else { return }
        let budget = pacer.budget
        if budget.isStopped && drawnStill {
            link.isPaused = true
        } else {
            let fps = Float(max(1, budget.framesPerSecond))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 10), maximum: fps, preferred: fps)
            link.isPaused = false
        }
        // actions keep their time while nothing is drawn, so `play` returns
        if link.isPaused && character.hasPendingActions { startHiddenTicker() } else { stopHiddenTicker() }
    }

    private func startHiddenTicker() {
        guard hiddenTicker == nil else { return }
        hiddenLast = CACurrentMediaTime()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hiddenTick() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        hiddenTicker = t
    }

    private func stopHiddenTicker() {
        hiddenTicker?.invalidate()
        hiddenTicker = nil
    }

    private func hiddenTick() {
        let now = CACurrentMediaTime()
        _ = character.advance(by: min(0.25, now - hiddenLast), input: frameInput())
        hiddenLast = now
        if !character.hasPendingActions { stopHiddenTicker() }
    }

    private func frameInput() -> FrameInput {
        var input = FrameInput(framing: framing, reduceMotion: pacer.signals.reduceMotion)
        guard let window else { return input }
        func canvas(_ screen: NSPoint) -> CGPoint {
            canvasPoint(convert(window.convertPoint(fromScreen: screen), from: nil))
        }
        switch character.lookTarget {
        case .pointer:
            if isInteractive { input.pointer = canvas(NSEvent.mouseLocation) }
        case .point(let p):
            input.lookPoint = canvas(p)
        case .ahead:
            break
        }
        return input
    }

    // MARK: Frames

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        // a long gap (asleep, hidden) is not time the character lived through
        let dt = lastTimestamp > 0 ? min(0.1, max(0, now - lastTimestamp)) : 0
        lastTimestamp = now
        let started = CACurrentMediaTime()
        let moving = character.advance(by: dt, input: frameInput())

        var signals = pacer.signals
        signals.explicitlyPaused = character.isPaused
        signals.characterAtRest = !moving
        let level = character.speechLevel ?? character.speechSource?.speechLevel ?? 0
        signals.speaking = moving && level > 0.01
        if signals != pacer.signals { pacer.signals = signals }

        draw()
        stats.recordCPU(CACurrentMediaTime() - started)
        if !moving { drawnStill = true }
        applyBudget()
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard isReady, let queue, let drawable = currentDrawable, bounds.width > 0, bounds.height > 0,
              let cb = queue.makeCommandBuffer() else { return }
        let scale = CGFloat(drawable.texture.width) / bounds.width
        let target = RenderTarget(texture: drawable.texture, scale: scale, framing: framing, quality: pacer.budget.quality)
        character.encode(into: target, commandBuffer: cb)
        let stats = stats
        cb.addCompletedHandler { cb in
            if cb.gpuEndTime > cb.gpuStartTime { stats.recordGPU(cb.gpuEndTime - cb.gpuStartTime) }
        }
        cb.present(drawable)
        cb.commit()
    }

    private func updateAccessibilityLabel() {
        var label = "\(type(of: character).characterID), \(character.state.rawValue)"
        if let e = character.expression { label += ", \(e.rawValue)" }
        setAccessibilityLabel(label)
    }
}

/// Recent frame timings: CPU time to advance and encode, and GPU time, as moving averages in seconds.
public final class FrameStats: Sendable {
    private struct Values {
        var cpu = 0.0
        var gpu = 0.0
        var frames = 0
    }
    private let values = Mutex(Values())

    public init() {}

    public var cpuTime: Double { values.withLock { $0.cpu } }
    public var gpuTime: Double { values.withLock { $0.gpu } }
    /// Frames drawn since the view was made.
    public var frames: Int { values.withLock { $0.frames } }

    func recordCPU(_ t: Double) {
        values.withLock {
            $0.cpu = $0.frames == 0 ? t : $0.cpu * 0.95 + t * 0.05
            $0.frames += 1
        }
    }

    func recordGPU(_ t: Double) {
        values.withLock { $0.gpu = $0.gpu == 0 ? t : $0.gpu * 0.95 + t * 0.05 }
    }
}
