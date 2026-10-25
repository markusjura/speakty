import SwiftUI

/// One row per local model, with its download state. Only Parakeet Ultra exists for now, so it is
/// the selected model whenever it's downloaded.
struct ModelsSettingsPane: View {
    let transcriber: Transcriber

    var body: some View {
        Form {
            Section("Dictation model") {
                ForEach(DictationModel.allCases) { model in
                    ModelRow(model: model, transcriber: transcriber)
                }
            }
        }
    }
}

private struct ModelRow: View {
    let model: DictationModel
    let transcriber: Transcriber
    @State private var confirmsRemoval = false

    var body: some View {
        let state = transcriber.state
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RadioButton(isOn: state == .ready)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                Text(model.summary).font(.callout).settingsValue()
                detail(state)
            }
            Spacer()
            action(state)
        }
        .padding(.vertical, 10)
        .confirmationDialog("Remove \(model.title)?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) { transcriber.remove() }
        } message: {
            Text("Dictation stops working until you download it again.")
        }
    }

    @ViewBuilder private func detail(_ state: Transcriber.State) -> some View {
        switch state {
        case .downloading(let fraction):
            ProgressView(value: fraction).frame(maxWidth: 260)
            Text("Downloading · \(fraction.formatted(.percent.precision(.fractionLength(0)))) of \(model.size)")
                .font(.callout).monospacedDigit().settingsValue()
        case .loading:
            Text("Loading onto the Neural Engine…").font(.callout).settingsValue()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle").font(.callout).settingsValue()
        case .absent, .ready:
            Text(model.size).font(.callout).settingsValue()
        }
    }

    @ViewBuilder private func action(_ state: Transcriber.State) -> some View {
        switch state {
        case .absent: Button("Download") { transcriber.prepare() }.buttonStyle(SettingsButtonStyle(isProminent: true))
        case .failed: Button("Try Again") { transcriber.prepare() }
        case .ready: Button("Remove") { confirmsRemoval = true }
        case .downloading, .loading: EmptyView()
        }
    }
}

/// The selection radio, drawn by a one-option radio group: SwiftUI has radios only in pickers, and
/// this is the same control as the Theme picker, so its blue matches. It only shows the state: the
/// model is selected once it's ready.
private struct RadioButton: View {
    let isOn: Bool

    var body: some View {
        Picker(selection: .constant(isOn)) {
            Text(verbatim: "").tag(true)
        } label: {
            EmptyView()
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
        // Not the settings row layout, whose spacer would push the radio off the leading edge.
        .labeledContentStyle(.automatic)
        // Just the circle, without the room for its empty option title.
        .fixedSize()
        .frame(width: 16, alignment: .leading)
        .allowsHitTesting(false)
        // A status, not a control VoiceOver could try to change.
        .accessibilityRepresentation { Text(isOn ? "Selected" : "Not downloaded") }
    }
}
