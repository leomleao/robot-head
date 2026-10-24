// Measure mode: one scenario, the robot alone, then a single JSON line on
// stdout. It settles first (pipelines compiled, the window shown, the pacer
// past its first decisions), then counts frames and the process's CPU time
// over the sampling window. Nothing moves the mouse: what the pointer does is
// whatever the person running it does, which for these runs is nothing.

import AppKit
import CharacterKit
import IronGiant

struct MeasureOptions {
    enum Scenario: String, CaseIterable {
        /// Idle in a window, pointer still.
        case idle
        /// Speaking with a live speech source playing generated speech.
        case speaking
        /// Speaking with no source: the sim's own talking.
        case procedural
        /// `isPaused`.
        case paused
        /// Idle in a miniaturised window, so occlusion stops drawing.
        case hidden
        /// Idle in the floating panel with click-through on.
        case panel
    }

    var scenario: Scenario
    var seconds = 30.0
    var size: CGFloat = 240
    var budget = BudgetChoice.auto

    static let usage = "usage: RobotPlayground --measure <\(Scenario.allCases.map(\.rawValue).joined(separator: "|"))> [--seconds 30] [--size 240] [--budget auto|full|reduced|low]"

    /// The options in `arguments` (without the program name), or nil when there is no `--measure`.
    /// Throws the usage for anything malformed.
    init?(arguments: [String]) throws(UsageError) {
        guard arguments.contains("--measure") else { return nil }
        func value(after flag: String) throws(UsageError) -> String? {
            guard let i = arguments.firstIndex(of: flag) else { return nil }
            guard i + 1 < arguments.count else { throw UsageError() }
            return arguments[i + 1]
        }
        guard let name = try value(after: "--measure"), let scenario = Scenario(rawValue: name) else { throw UsageError() }
        self.scenario = scenario
        if let s = try value(after: "--seconds") {
            guard let v = Double(s), v > 0 else { throw UsageError() }
            seconds = v
        }
        if let s = try value(after: "--size") {
            guard let v = Double(s), v >= 16 else { throw UsageError() }
            size = v
        }
        if let s = try value(after: "--budget") {
            guard let v = BudgetChoice(rawValue: s) else { throw UsageError() }
            budget = v
        }
    }

    struct UsageError: Error {}
}

@MainActor
final class Measurement {
    /// Time to settle before sampling: shader compile, first frames, the window's animations.
    static let settle: Duration = .seconds(3)

    let options: MeasureOptions
    private let character = IronGiantCharacter(seed: 0.3)
    private var window: NSWindow?
    private let panel = FloatingPanelController()
    private let speech = SpeechPlayer()

    init(options: MeasureOptions) {
        self.options = options
    }

    func start() {
        let view = makeStage()
        view.pacer.forcedBudget = options.budget.budget

        switch options.scenario {
        case .idle, .panel, .hidden:
            break
        case .speaking:
            character.state = .speaking
            // enough speech to outlast the settle and the sampling window
            let buffer = SpeechBuffer.make(seconds: 3 + options.seconds + 2)
            // the jaw reads the buffer's own levels, so the speakers can stay silent
            speech.volume = 0
            do {
                try speech.play(buffer: buffer)
                character.speechSource = speech
            } catch {
                fail("can't play the generated speech: \(error)")
            }
        case .procedural:
            character.state = .speaking
        case .paused:
            character.isPaused = true
        }

        Task {
            if options.scenario == .hidden {
                // let it draw first, so hiding it is what stops it
                try? await Task.sleep(for: .milliseconds(500))
                window?.miniaturize(nil)
            }
            try? await Task.sleep(for: Self.settle)
            let frames = view.stats.frames, cpu = processCPUTime(), wall = CACurrentMediaTime()
            try? await Task.sleep(for: .seconds(options.seconds))
            report(view: view, frames: view.stats.frames - frames, cpu: processCPUTime() - cpu, wall: CACurrentMediaTime() - wall)
        }
    }

    /// The robot alone: in a plain window, or in the floating panel.
    private func makeStage() -> CharacterView {
        if options.scenario == .panel {
            panel.box = options.size
            return panel.show(character)
        }
        let size = CharacterView.canvasSize(for: character, box: options.size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RobotPlayground — \(options.scenario.rawValue)"
        window.isReleasedWhenClosed = false
        let view = CharacterView(character: character)
        view.preferredBox = options.size
        window.contentView = view
        // above the terminal that started it: activation is only a request, and a covered
        // window would measure occlusion instead of drawing
        window.level = .floating
        window.center()
        window.orderFrontRegardless()
        self.window = window
        return view
    }

    private func report(view: CharacterView, frames: Int, cpu: Double, wall: Double) {
        func number(_ v: Double) -> String { String(format: "%.2f", v) }
        // a frame time only means something if frames were drawn while sampling
        let perFrame = { (t: Double) in frames > 0 ? number(t * 1000) : "null" }
        let fields = [
            "\"scenario\":\"\(options.scenario.rawValue)\"",
            "\"seconds\":\(number(wall))",
            "\"size\":\(number(Double(options.size)))",
            "\"budget\":\"\(options.budget.rawValue)\"",
            "\"fps\":\(number(Double(frames) / wall))",
            "\"cpuPercent\":\(number(cpu / wall * 100))",
            "\"cpuMsPerFrame\":\(perFrame(view.stats.cpuTime))",
            "\"gpuMsPerFrame\":\(perFrame(view.stats.gpuTime))",
            "\"frames\":\(frames)",
        ]
        let budget = view.pacer.budget
        FileHandle.standardError.write(Data("pacer at the end: \(budget.framesPerSecond) fps, \(budget.quality); \(LiveStats(signals: view.pacer.signals).activeSignals)\n".utf8))
        print("{" + fields.joined(separator: ",") + "}")
        fflush(stdout)
        speech.stop()
        exit(0)
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("RobotPlayground: \(message)\n".utf8))
        exit(1)
    }
}
