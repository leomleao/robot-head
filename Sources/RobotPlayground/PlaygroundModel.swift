// What the playground controls, held in one place: the character, the
// settings the site's controls set, and the readouts. Settings write straight
// through to the character, so the character stays the only source of truth
// for what is drawn; the model only remembers what the controls show.

import AppKit
import CharacterKit
import IronGiant
import Observation
import SwiftUI

/// The site's background, by day or by night.
enum Theme: String {
    case dark, light

    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

/// Where the eyes go, as the look-target control offers it.
enum LookChoice: String, CaseIterable, Identifiable {
    case pointer, ahead, topLeft, bottomRight

    var id: Self { self }

    var label: String {
        switch self {
        case .pointer: "Pointer"
        case .ahead: "Ahead"
        case .topLeft: "↖ Corner"
        case .bottomRight: "↘ Corner"
        }
    }

    /// The screen corners are the main screen's, in global AppKit points (y up).
    var target: LookTarget {
        let frame = NSScreen.screens.first?.frame ?? .zero
        switch self {
        case .pointer: return .pointer
        case .ahead: return .ahead
        case .topLeft: return .point(CGPoint(x: frame.minX, y: frame.maxY))
        case .bottomRight: return .point(CGPoint(x: frame.maxX, y: frame.minY))
        }
    }
}

/// The quality override: Auto follows the pacer's policy; the rest force one of its rows.
enum BudgetChoice: String, CaseIterable, Identifiable {
    case auto, full, reduced, low

    var id: Self { self }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .full: "Full"
        case .reduced: "Reduced"
        case .low: "Low"
        }
    }

    var budget: RenderBudget? {
        let policy = PacingPolicy.standard
        switch self {
        case .auto: return nil
        case .full: return policy.full
        case .reduced: return policy.relaxed
        case .low: return policy.constrained
        }
    }
}

@MainActor
@Observable
final class PlaygroundModel {
    /// The robot every view shows. Replaced when the seed changes.
    private(set) var character: IronGiantCharacter
    /// Changes whenever a new view must be made for the character (a new seed, or back from the panel).
    private(set) var viewGeneration = 0

    var seed: Double {
        didSet { if seed != oldValue { remake() } }
    }

    var state: CharacterState = .idle { didSet { character.state = state } }
    var expression: CharacterExpression? { didSet { character.expression = expression } }
    var shell = Swatch.shells[0].color { didSet { applyPalette() } }
    var eyes = Swatch.eyes[0].color { didSet { applyPalette() } }
    var speed = 1.0 { didSet { character.speed = speed } }
    var isPaused = false { didSet { character.isPaused = isPaused } }
    var showsFloorShadow = true { didSet { character.showsFloorShadow = showsFloorShadow } }
    var isInteractive = true { didSet { view?.isInteractive = isInteractive } }
    var look = LookChoice.pointer { didSet { character.lookTarget = look.target } }
    var budget = BudgetChoice.auto { didSet { view?.pacer.forcedBudget = budget.budget } }
    var theme = Theme.dark

    /// Auto lets the character talk on its own, or from the audio file; off holds the jaw at ``mouth``.
    var mouthAuto = true { didSet { applyMouth() } }
    var mouth = 0.5 { didSet { applyMouth() } }

    /// How long `defense` holds the guard, in seconds.
    var defenseHold = 2.0
    /// The action playing now, as the dock shows it.
    private(set) var playing: CharacterAction?
    /// The last action that ended, and how.
    private(set) var lastOutcome: (action: CharacterAction, outcome: ActionOutcome)?

    /// The audio file being lip-synced, while it plays.
    private(set) var speechFile: String?
    private(set) var speechError: String?
    private let speech = SpeechPlayer()

    /// The view drawing the character now: the stage's, or the panel's while it is open.
    private(set) weak var view: CharacterView?
    let panel = FloatingPanelController()
    /// Whether the robot is out in the floating panel.
    private(set) var isPanelOpen = false
    private(set) var stats = LiveStats()
    private let sampler = StatsSampler()
    private var timer: Timer?

    init(seed: Double = 0.3) {
        self.seed = seed
        character = IronGiantCharacter(seed: seed)
        panel.onClose = { [weak self] in self?.panelClosed() }
        // the voice ended: the mouth goes back to the sim's own talking
        speech.onFinish = { [weak self] in
            self?.speechFile = nil
            self?.applyMouth()
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Character

    /// A new robot with the new seed, wearing everything the controls say.
    private func remake() {
        character = IronGiantCharacter(seed: seed)
        character.state = state
        character.expression = expression
        character.speed = speed
        character.isPaused = isPaused
        character.showsFloorShadow = showsFloorShadow
        character.lookTarget = look.target
        applyPalette()
        applyMouth()
        playing = nil
        viewGeneration += 1
        if isPanelOpen { attach(panel.show(character)) }
    }

    private func applyPalette() {
        character.palette = CharacterPalette(body: shell, eyes: eyes)
    }

    private func applyMouth() {
        character.speechLevel = mouthAuto ? nil : Float(mouth)
        character.speechSource = mouthAuto && speech.isPlaying ? speech : nil
    }

    /// Back to the site's defaults (the seed stays).
    func reset() {
        expression = nil
        shell = Swatch.shells[0].color
        eyes = Swatch.eyes[0].color
        speed = 1
        isPaused = false
        showsFloorShadow = true
        isInteractive = true
        look = .pointer
        mouthAuto = true
        budget = .auto
    }

    // MARK: Views

    /// The stage's view was made: it draws until the panel takes over.
    func stageViewMade(_ view: CharacterView) {
        guard !isPanelOpen else { return }
        attach(view)
    }

    private func attach(_ view: CharacterView) {
        self.view = view
        view.isInteractive = isInteractive
        view.pacer.forcedBudget = budget.budget
        sampler.restart(frames: view.stats.frames)
    }

    /// A character can live in one view at a time (each view advances it every frame and takes
    /// its `onChange`), so the stage gives the robot up while the panel is open.
    func togglePanel() {
        if isPanelOpen {
            panel.close()
        } else {
            attach(panel.show(character))
            isPanelOpen = true
        }
    }

    private func panelClosed() {
        // the stage makes a fresh view, which takes the character's `onChange` back
        isPanelOpen = false
        viewGeneration += 1
    }

    // MARK: Actions

    func play(_ action: CharacterAction) {
        playing = action
        let options = action == .defense ? ActionOptions(hold: .milliseconds(Int(defenseHold * 1000))) : ActionOptions()
        let character = character
        Task {
            let outcome = await character.play(action, options: options)
            guard character === self.character else { return }
            lastOutcome = (action, outcome)
            if playing == action { playing = nil }
        }
    }

    // MARK: Lip-sync

    func chooseSpeechFile() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.audio]
        open.allowsMultipleSelection = false
        guard open.runModal() == .OK, let url = open.url else { return }
        do {
            try speech.play(url: url)
            speechFile = url.lastPathComponent
            speechError = nil
            mouthAuto = true
            state = .speaking
            applyMouth()
        } catch {
            speechFile = nil
            speechError = "Can't play \(url.lastPathComponent)"
        }
    }

    func stopSpeech() {
        speech.stop()
        speechFile = nil
        applyMouth()
    }

    // MARK: Readouts

    private func tick() {
        guard let view else { return }
        stats = sampler.sample(view)
    }
}

/// A named colour from the site's swatches.
struct Swatch: Identifiable {
    let name: String
    let color: CharacterColor
    var id: String { name }

    init(_ name: String, _ hex: String) {
        self.name = name
        color = CharacterColor(hex: hex)!
    }

    static let shells = [
        Swatch("Gunmetal", "#3c373f"), Swatch("Iron", "#4a4744"), Swatch("Rust", "#6b3f2e"), Swatch("Bronze", "#7a5a3a"),
        Swatch("Navy", "#2c3550"), Swatch("Moss", "#3d4a35"), Swatch("Ash", "#8a8580"),
    ]
    static let eyes = [Swatch("Warm", "#ffece2"), Swatch("Amber", "#ffb347"), Swatch("Moonlight", "#bfe3ff"), Swatch("Mint", "#c8ffd9")]
}
