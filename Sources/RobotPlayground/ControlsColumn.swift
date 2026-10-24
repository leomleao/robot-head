// The column of controls on the right: looks first, as on the site, then the
// things only the native port has (mouth, lip-sync, gaze, pacing and the
// readouts that show what the pacer is doing).

import AppKit
import CharacterKit
import SwiftUI

struct ControlsColumn: View {
    @Bindable var model: PlaygroundModel

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            SwatchRow(label: "Shell", swatches: Swatch.shells, value: $model.shell)
            SwatchRow(label: "Eyes", swatches: Swatch.eyes, value: $model.eyes)

            Control("Expression", value: model.expression?.rawValue ?? "the state's own") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 4)], alignment: .leading, spacing: 4) {
                    Chip("none", on: model.expression == nil) { model.expression = nil }
                    ForEach(CharacterExpression.core, id: \.self) { e in
                        Chip(e.rawValue, on: model.expression == e) { model.expression = e }
                    }
                }
            }

            Control("Speed", value: model.isPaused ? "paused" : "\(model.speed.formatted())×") {
                Segments(options: [0.5, 1, 1.5, 2], selection: $model.speed) { "\($0.formatted())×" }
                Toggle("Paused", isOn: $model.isPaused)
            }

            Control("Behaviour") {
                Toggle("Interactive (follow the pointer, poke on click)", isOn: $model.isInteractive)
                Toggle("Floor shadow", isOn: $model.showsFloorShadow)
                HStack {
                    Text("Seed")
                    Slider(value: $model.seed, in: 0...1, step: 0.05)
                    Text(model.seed.formatted(.number.precision(.fractionLength(2))))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Control("Mouth", value: model.mouthAuto ? "auto" : model.mouth.formatted(.number.precision(.fractionLength(2)))) {
                HStack {
                    Toggle("Auto", isOn: $model.mouthAuto)
                    Slider(value: $model.mouth, in: 0...1)
                        .disabled(model.mouthAuto)
                }
                HStack {
                    Button(model.speechFile == nil ? "Lip-sync a file…" : "Stop") {
                        if model.speechFile == nil { model.chooseSpeechFile() } else { model.stopSpeech() }
                    }
                    Text(model.speechFile ?? model.speechError ?? "")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }

            Control("Look at") {
                Segments(options: LookChoice.allCases, selection: $model.look) { $0.label }
            }

            HStack {
                Spacer()
                Button("Reset") { model.reset() }
            }
        }
        .font(.system(size: 13))
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }
}

/// Pacing, under the dock: the quality override, what the view and the pacer are doing, and the panel.
struct PacingColumn: View {
    @Bindable var model: PlaygroundModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Control("Quality", value: model.stats.isForced ? "forced" : "pacer") {
                Segments(options: BudgetChoice.allCases, selection: $model.budget) { $0.label }
                Readouts(stats: model.stats)
            }
            Button(model.isPanelOpen ? "Close floating panel" : "Floating panel") { model.togglePanel() }
        }
        .font(.system(size: 13))
        .controlSize(.small)
    }
}

/// A quiet label over its control, as on the site.
struct Control<Content: View>: View {
    let label: String
    var value = ""
    @ViewBuilder let content: Content

    init(_ label: String, value: String = "", @ViewBuilder content: () -> Content) {
        self.label = label
        self.value = value
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            content
        }
    }
}

struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    init(_ title: String, on: Bool, action: @escaping () -> Void) {
        self.title = title
        self.on = on
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(on ? .primary : .secondary)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(on ? Color.primary.opacity(0.12) : Color.primary.opacity(0.045), in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The site's segmented row: one of a few values.
struct Segments<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(option == selection ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(option == selection ? Color.primary.opacity(0.1) : .clear, in: .rect(cornerRadius: 7))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityAddTraits(option == selection ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 10))
    }
}

/// The site's swatches, plus the system colour picker for anything else.
struct SwatchRow: View {
    let label: String
    let swatches: [Swatch]
    @Binding var value: RGBColor

    var body: some View {
        let known = swatches.first { $0.color == value }
        Control(label, value: known?.name ?? value.hex) {
            HStack(spacing: 8) {
                ForEach(swatches) { s in
                    Button {
                        value = s.color
                    } label: {
                        Circle()
                            .fill(Color(s.color))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                            .frame(width: 20, height: 20)
                            .padding(3)
                            .overlay(Circle().strokeBorder(s.color == value ? Color.primary : .clear, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(s.name)
                    .accessibilityLabel("\(label): \(s.name)")
                }
                ColorPicker("Custom", selection: Binding(get: { Color(value) }, set: { value = RGBColor($0) }), supportsOpacity: false)
                    .labelsHidden()
                    .help("Custom")
            }
        }
    }
}

/// What the view and the pacer are doing, refreshed once a second.
struct Readouts: View {
    let stats: LiveStats

    var body: some View {
        let f = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1))
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            GridRow { Text("drawn"); Text("\(stats.fps.formatted(f)) fps") }
            GridRow { Text("CPU / frame"); Text("\(stats.cpuMs.formatted(.number.precision(.fractionLength(2)))) ms") }
            GridRow { Text("GPU / frame"); Text("\(stats.gpuMs.formatted(.number.precision(.fractionLength(2)))) ms") }
            GridRow { Text("process CPU"); Text("\(stats.cpuPercent.formatted(f)) %") }
            GridRow { Text("budget"); Text("\(stats.budget.framesPerSecond) fps, \(String(describing: stats.budget.quality))\(stats.isForced ? " (forced)" : "")") }
            GridRow(alignment: .top) {
                Text("signals")
                Text(stats.activeSignals.isEmpty ? "none" : stats.activeSignals.joined(separator: ", "))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}

extension Color {
    init(_ c: RGBColor) {
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }
}

extension RGBColor {
    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }
}
