// The window, laid out like site/src/App.tsx so the two can sit side by side:
// the action dock down the left, the robot large in the middle with its
// caption, the controls down the right and the states along the bottom.

import CharacterKit
import SwiftUI

/// What each state does, in his own words and then in ours (site/src/App.tsx).
let stateHints: [CharacterState: (said: String, what: String)] = [
    .idle: ("Hmm.", "Slow glances, slow blinks, the odd tilt of the head."),
    .thinking: ("Hmm?", "Looking up, to one side and then the other."),
    .searching: ("Rockwell?", "A slow sweep, the eyes a step ahead of the head."),
    .listening: ("Mm-hmm.", "Head cocked toward you, nodding along."),
    .speaking: ("You stay. I go.", "Short words, a pause between. Give it audio to lip-sync."),
    .working: ("I fix.", "Eyes down on the work, careful."),
    .happy: ("Rockwell!", "A hop, a grin, a sway."),
    .error: ("Awww.", "A slow shake of the head. Never red: red is for danger."),
    .sleeping: ("…", "Shut down and breathing. Wake it to watch the eyes come back."),
]

let actionLabels: [CharacterAction: String] = [
    .blink: "Blink", .nod: "Nod", .shake: "Shake", .hmm: "Hmm?", .laugh: "Laugh", .surprise: "Surprise", .wake: "Wake", .defense: "Defense",
]

extension String {
    var titled: String { prefix(1).uppercased() + dropFirst() }
}

struct PlaygroundView: View {
    @Bindable var model: PlaygroundModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ActionDock(model: model)
                PacingColumn(model: model)
                    .padding(.top, 36)
                Spacer(minLength: 0)
            }
            .padding(.leading, 24)
            .padding(.top, 52)
            .padding(.bottom, 24)
            .frame(width: 250)
            VStack(spacing: 0) {
                Stage(model: model)
                StatePicker(model: model)
            }
            ScrollView {
                ControlsColumn(model: model)
                    .padding(.horizontal, 24)
                    .padding(.top, 52)
                    .padding(.bottom, 24)
            }
            .frame(width: 340)
        }
        .background { StageBackground(theme: model.theme) }
        .overlay(alignment: .topTrailing) {
            Button {
                model.theme = model.theme == .dark ? .light : .dark
            } label: {
                Image(systemName: model.theme == .dark ? "sun.max" : "moon")
                    .font(.system(size: 15))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(model.theme == .dark ? "Light mode" : "Dark mode")
            .accessibilityLabel(model.theme == .dark ? "Switch to light mode" : "Switch to dark mode")
            .padding(.top, 10)
            .padding(.trailing, 16)
        }
        .preferredColorScheme(model.theme.colorScheme)
        .frame(minWidth: 1100, minHeight: 760)
    }
}

/// The site's stage: a soft glow behind the robot, fading to the page.
struct StageBackground: View {
    let theme: Theme

    var body: some View {
        let (glow, page): (Color, Color) = theme == .dark
            ? (Color(red: 0x13 / 255, green: 0x13 / 255, blue: 0x16 / 255), Color(red: 0x0a / 255, green: 0x0a / 255, blue: 0x0b / 255))
            : (.white, Color(red: 0xf3 / 255, green: 0xf3 / 255, blue: 0xf1 / 255))
        GeometryReader { geo in
            RadialGradient(colors: [glow, page], center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0, endRadius: max(geo.size.width, geo.size.height) / 2)
        }
        .ignoresSafeArea()
    }
}

struct Stage: View {
    @Bindable var model: PlaygroundModel

    var body: some View {
        let hint = stateHints[model.state] ?? ("", "")
        VStack(spacing: 28) {
            if model.isPanelOpen {
                VStack(spacing: 12) {
                    Text("The robot is out on the desktop.")
                        .foregroundStyle(.secondary)
                    Button("Bring it back") { model.togglePanel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CharacterViewRepresentable(
                    character: model.character,
                    isInteractive: model.isInteractive,
                    forcedBudget: model.budget.budget,
                    onMake: { model.stageViewMade($0) }
                )
                .id(model.viewGeneration)
                .frame(maxWidth: 520, maxHeight: 520)
            }
            VStack(spacing: 6) {
                Text((model.expression?.rawValue ?? model.state.rawValue).titled)
                    .font(.system(size: 30, weight: .bold))
                Text("“\(hint.said)” \(Text(hint.what).foregroundStyle(.secondary))")
                    .font(.system(size: 14))
            }
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The states along the bottom.
struct StatePicker: View {
    @Bindable var model: PlaygroundModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(CharacterState.allCases, id: \.self) { s in
                Button {
                    model.state = s
                } label: {
                    Text(s.rawValue.titled)
                        .font(.system(size: 12.5))
                        .foregroundStyle(s == model.state ? .primary : .secondary)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(s == model.state ? Color.primary.opacity(0.09) : .clear, in: .rect(cornerRadius: 7))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("State: \(s.rawValue)")
                .accessibilityAddTraits(s == model.state ? .isSelected : [])
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

/// The actions down the left, with defense's hold, what is playing and how the last one ended.
struct ActionDock: View {
    @Bindable var model: PlaygroundModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Actions")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            ForEach(CharacterAction.core, id: \.self) { a in
                Button {
                    model.play(a)
                } label: {
                    HStack {
                        Text(actionLabels[a] ?? a.rawValue)
                        Spacer()
                        if model.playing == a { Image(systemName: "play.fill").font(.system(size: 9)) }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(model.playing == a ? Color.primary.opacity(0.12) : Color.primary.opacity(0.045), in: .rect(cornerRadius: 8))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Action: \(actionLabels[a] ?? a.rawValue)")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Defense hold \(model.defenseHold, format: .number.precision(.fractionLength(1))) s")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: $model.defenseHold, in: 0.5...6, step: 0.5)
                    .controlSize(.small)
            }
            .padding(.top, 8)
            Group {
                Text("Playing: \(model.playing?.rawValue ?? "nothing")")
                // always there, two lines high, so nothing under it moves when it fills in
                Text("Last: " + (model.lastOutcome.map { "\($0.action.rawValue) → \(String(describing: $0.outcome))" } ?? "none"))
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .frame(width: 170)
    }
}
