import SwiftUI

struct TranscriptSettingsPane: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Form {
            VocabularySection(words: $preferences.transcript.vocabulary)
            ReplacementsSection(replacements: $preferences.transcript.replacements)
            Section("Pasting") {
                Toggle("Smart spacing and capitalization", isOn: $preferences.transcript.matchesSurroundingText)
            }
        }
    }
}

// MARK: Vocabulary

/// One field adds and finds. Return adds what's typed, split at commas and line breaks, so a pasted
/// list adds every word. Typing filters the words below; a click on a word edits it in place, and its ×
/// removes it. New words go first.
private struct VocabularySection: View {
    @Binding var words: [String]
    @State private var query = ""
    @State private var editing: String?
    @State private var draft = ""
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case field, word }

    var body: some View {
        Section {
            HStack(spacing: 7) {
                Image(systemName: "plus").foregroundStyle(focus == .field ? Color.accentColor : SettingsColor.secondaryText)
                TextField("Add words, or type to find", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .field)
                    .onSubmit { add(query) }
                    .onExitCommand { query = "" }
                if canAdd {
                    // The Return key that adds, as a keycap hint.
                    Button("Add", systemImage: "return") { add(query) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SettingsColor.secondaryText)
                        .frame(width: 22, height: 18)
                        .background(SettingsColor.controlFill, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            if !shown.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(shown, id: \.self, content: chip)
                }
                .padding(.vertical, 10)
            }
        } header: {
            HStack {
                Text("Vocabulary")
                Spacer()
                Text(trimmed.isEmpty ? "\(words.count) words" : "\(shown.count) of \(words.count)")
                    .font(.callout.weight(.regular)).monospacedDigit().settingsValue()
            }
        }
        .onChange(of: focus) { if focus != .word, editing != nil { commitEdit() } }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var shown: [String] {
        trimmed.isEmpty ? words : words.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var canAdd: Bool {
        !trimmed.isEmpty && !words.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    @ViewBuilder private func chip(_ word: String) -> some View {
        if editing == word {
            // Sized by the text and with the remove button's room kept, so the chip keeps its shape
            // and editing doesn't move the words after it.
            HStack(spacing: WordChip.spacing) {
                Text(draft).hidden().overlay {
                    TextField("Word", text: $draft)
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .focused($focus, equals: .word)
                        .onSubmit(commitEdit)
                        .onExitCommand { editing = nil }
                }
                Color.clear.frame(width: WordChip.removeSize)
            }
            .chipPadding()
            .background(SettingsColor.canvas, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 2))
        } else {
            WordChip(word: word, highlight: trimmed) {
                draft = word
                editing = word
                focus = .word
            } remove: {
                words.removeAll { $0 == word }
            }
        }
    }

    private func add(_ text: String) {
        var added: [String] = []
        for word in text.split(whereSeparator: { $0 == "," || $0.isNewline }).map({ $0.trimmingCharacters(in: .whitespaces) })
            where !word.isEmpty && !(added + words).contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            added.append(word)
        }
        words.insert(contentsOf: added, at: 0)
        query = ""
        // Also after a click on the Return keycap, so the next word can follow.
        focus = .field
    }

    /// An empty word removes it; a word that already exists elsewhere leaves the original.
    private func commitEdit() {
        guard let original = editing, let index = words.firstIndex(of: original) else { return editing = nil }
        editing = nil
        let word = draft.trimmingCharacters(in: .whitespaces)
        if word.isEmpty {
            words.remove(at: index)
        } else if !words.enumerated().contains(where: { $0.offset != index && $0.element.caseInsensitiveCompare(word) == .orderedSame }) {
            words[index] = word
        }
    }
}

/// A word as a token with its remove button always shown, so the chip keeps one shape whether or
/// not the pointer is over it.
private struct WordChip: View {
    let word: String
    let highlight: String
    let edit: () -> Void
    let remove: () -> Void
    @State private var isHoveringRemove = false

    static let spacing: CGFloat = 3
    static let removeSize: CGFloat = 16

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(highlighted).lineLimit(1)
            Button("Remove \(word)", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isHoveringRemove ? SettingsColor.primaryText : SettingsColor.secondaryText)
                .frame(width: Self.removeSize, height: Self.removeSize)
                .background(SettingsColor.primaryText.opacity(isHoveringRemove ? 0.12 : 0), in: Circle())
                .contentShape(Circle())
                .onHover { isHoveringRemove = $0 }
        }
        .chipPadding()
        .background(SettingsColor.controlFill, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: edit)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Edit", edit)
        .accessibilityAction(named: "Remove", remove)
    }

    /// The word with the part matching the search in the accent color.
    private var highlighted: AttributedString {
        var text = AttributedString(word)
        if !highlight.isEmpty, let range = text.range(of: highlight, options: .caseInsensitive) {
            text[range].foregroundColor = .accentColor
            text[range].font = .body.weight(.semibold)
        }
        return text
    }
}

private extension View {
    /// A word chip's insets: the trailing one is smaller, since the remove button's circle has its own room.
    func chipPadding() -> some View {
        padding(.leading, 10).padding(.trailing, 4).frame(height: 24)
    }
}

/// Lays subviews out left to right, wrapping to a new line when the next one doesn't fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + lineHeight + spacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

// MARK: Replacements

/// The rules in order, each removable, with one form below to add a rule or change the one clicked.
private struct ReplacementsSection: View {
    @Binding var replacements: [Replacement]
    @State private var draft = Replacement(find: "", replacement: "")
    @State private var editing: Replacement.ID?

    var body: some View {
        Section("Replacements") {
            ForEach(replacements) { rule in
                ReplacementRow(rule: rule, isEditing: rule.id == editing) {
                    draft = rule
                    editing = rule.id
                } remove: {
                    replacements.removeAll { $0.id == rule.id }
                    if editing == rule.id { reset() }
                }
            }
            HStack(spacing: 8) {
                TextField("Find", text: $draft.find).settingsTextField()
                Image(systemName: "arrow.right").foregroundStyle(SettingsColor.secondaryText)
                TextField("Replace with", text: $draft.replacement).settingsTextField()
                Toggle(".*", isOn: $draft.isPattern)
                    .toggleStyle(.button)
                    .font(.system(.callout, design: .monospaced))
                    .help("Regular expression: use $1 for its groups")
                if editing != nil { Button("Cancel", action: reset) }
                Button(editing == nil ? "Add" : "Save", action: save)
                    .disabled(!draft.isValid)
            }
            .onSubmit(save)
            .onExitCommand(perform: reset)
            .padding(.vertical, 8)
            .settingsRowWarning(draft.isPattern && !draft.find.isEmpty && !draft.isValid ? "Not a valid regular expression." : nil)
        }
    }

    private func save() {
        guard draft.isValid else { return }
        if let index = replacements.firstIndex(where: { $0.id == editing }) { replacements[index] = draft } else { replacements.append(draft) }
        reset()
    }

    private func reset() {
        draft = Replacement(find: "", replacement: "")
        editing = nil
    }
}

private struct ReplacementRow: View {
    let rule: Replacement
    let isEditing: Bool
    let edit: () -> Void
    let remove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            text(rule.find).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(SettingsColor.secondaryText)
            text(rule.replacement).frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove", systemImage: "xmark", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(SettingsColor.secondaryText)
                .opacity(isHovering ? 1 : 0)
        }
        .foregroundStyle(isEditing ? Color.accentColor : SettingsColor.primaryText)
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Edit", edit)
        .accessibilityAction(named: "Remove", remove)
    }

    /// Patterns in monospace, so their symbols read clearly.
    private func text(_ value: String) -> some View {
        Text(value.isEmpty ? "Nothing" : value)
            .font(rule.isPattern ? .system(.body, design: .monospaced) : .body)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
