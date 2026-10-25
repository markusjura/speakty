import SwiftUI

struct RecordingSettingsPane: View {
    @Bindable var preferences: AppPreferences
    @State private var inputs: [AudioInput] = []
    /// Moves every style preview like a voice while the pane is open.
    @State private var meter = LevelMeter.demo()

    var body: some View {
        Form {
            Section("Display") {
                LabeledContent("Style") {
                    HStack(spacing: 12) {
                        ForEach(OverlayStyle.allCases, id: \.self) { style in
                            StyleTile(style: style, recording: preferences.recording, meter: meter,
                                      isSelected: preferences.recording.style == style) {
                                preferences.recording.style = style
                            }
                        }
                    }
                    .fixedSize()
                    .padding(.vertical, 10)
                    // Without a container, the tiles and the Size slider below vanish from accessibility.
                    .accessibilityElement(children: .contain)
                }
                LabeledContent("Size") {
                    HStack {
                        // Rounded to whole percents instead of stepped, since a step draws a tick mark for every value.
                        Slider(value: Binding(get: { preferences.recording.scale },
                                              set: { preferences.recording.scale = ($0 * 100).rounded() / 100 }),
                               in: RecordingPreferences.scaleRange) {
                            Text("Size")
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        Text("\(Int((preferences.recording.scale * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Position", selection: $preferences.recording.position) {
                    Text("Bottom").tag(OverlayPosition.bottom)
                    Text("Top").tag(OverlayPosition.top)
                }
                .pickerStyle(.segmented)
                LabeledContent("Distance from edge") {
                    HStack {
                        // Rounded instead of stepped, since a step draws a tick mark for every value.
                        Slider(value: Binding(get: { preferences.recording.edgeDistance },
                                              set: { preferences.recording.edgeDistance = $0.rounded() }),
                               in: RecordingPreferences.edgeDistanceRange) {
                            Text("Distance from edge")
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        Text("\(Int(preferences.recording.edgeDistance)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Microphone") {
                Picker("Input", selection: $preferences.recording.microphoneUID) {
                    Text("System default").tag(String?.none)
                    Divider()
                    ForEach(inputs) { input in Text(input.name).tag(Optional(input.id)) }
                    if let uid = preferences.recording.microphoneUID, !inputs.contains(where: { $0.id == uid }) {
                        Text("Disconnected microphone").tag(Optional(uid))
                    }
                }
                .buttonStyle(.borderless)
                Toggle("Mute audio while recording", isOn: $preferences.recording.mutesAudio)
            }
        }
        .onAppear { meter.start() }
        .onDisappear { meter.stop() }
        .task {
            inputs = AudioDevices.inputs()
            for await _ in AudioDevices.changes() { inputs = AudioDevices.inputs() }
        }
    }
}

/// A style choice showing the real display, listening, on a small desktop, at the chosen size
/// and position.
private struct StyleTile: View {
    let style: OverlayStyle
    let recording: RecordingPreferences
    let meter: LevelMeter
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(LinearGradient(colors: [Color(red: 0.43, green: 0.49, blue: 0.79), Color(red: 0.71, green: 0.56, blue: 0.82),
                                                  Color(red: 0.91, green: 0.66, blue: 0.73)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 112, height: 66)
                    .overlay(alignment: recording.position.alignment) {
                        OverlayView(style: style, isTranscribing: false, meter: meter)
                            .scaleEffect(0.5 * recording.scale, anchor: recording.position.anchor)
                            .padding(.vertical, 7)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(isSelected ? Color.accentColor : SettingsColor.rowSeparator, lineWidth: isSelected ? 2 : 1)
                    }
                Text(style.title).fontWeight(isSelected ? .semibold : .regular)
            }
            .contentShape(Rectangle())
        }
        // A plain button, not the settings fill, so the tile is the whole control.
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension OverlayStyle {
    var title: String {
        switch self {
        case .dark: "Dark"
        case .glass: "Glass"
        case .orb: "Orb"
        }
    }
}
