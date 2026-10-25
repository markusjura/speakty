import SwiftUI

struct TranscriptSettingsPane: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Form {
            VocabularySection(words: $preferences.transcript.vocabulary)
            ReplacementsSection(replacements: $preferences.transcript.replacements)
            Section("Formatting") {
                Toggle("Smart spacing and capitalization", isOn: $preferences.transcript.matchesSurroundingText)
                Toggle("Smart paragraphs", isOn: $preferences.transcript.splitsParagraphs)
                    .help("Splits long dictations into paragraphs, and starts one where you say \"new paragraph\".")
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
                Color.clear.frame(width: RemoveButton.Size.chip.visible)
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

    static let spacing: CGFloat = 3

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text(highlighted).lineLimit(1)
            RemoveButton(title: "Remove \(word)", size: .chip, action: remove)
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

/// Removes a vocabulary word or a replacement. It lays out at its visible size, but takes clicks and
/// hover in a larger square around it, since a small glyph is a hard target.
private struct RemoveButton: View {
    enum Size {
        /// An × inside a word's pill, which fills a circle under the pointer, like a token's.
        case chip
        /// A filled circle with the × cut out beside a replacement's 28 pt controls, like a search
        /// field's clear button. One symbol, so the × is centered in its circle.
        case row

        /// The visible size, which sets the layout.
        var visible: CGFloat { self == .chip ? 16 : 18 }
        /// The chip's matches the shortcut recorder's 24 pt clear button; the row's spans the row's controls.
        var target: CGFloat { self == .chip ? 24 : 28 }
    }

    let title: String
    var size = Size.row
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            glyph
                .frame(width: size.visible, height: size.visible)
                .frame(width: size.target, height: size.target)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .onHover { isHovering = $0 }
        // Gives back the target's extra room, so the visible glyph alone sets the layout.
        .padding((size.visible - size.target) / 2)
    }

    @ViewBuilder private var glyph: some View {
        switch size {
        case .chip:
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isHovering ? SettingsColor.primaryText : SettingsColor.secondaryText)
                .frame(width: size.visible, height: size.visible)
                .background(SettingsColor.primaryText.opacity(isHovering ? 0.12 : 0), in: Circle())
        case .row:
            Image(systemName: "xmark.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(SettingsColor.secondaryText.opacity(isHovering ? 1 : 0.6))
        }
    }
}

private extension View {
    /// Centers the view in the space `placeholder` takes, so a column keeps one width whatever it shows.
    func sized(like placeholder: some View) -> some View {
        ZStack {
            placeholder.hidden().accessibilityHidden(true)
            self
        }
    }

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

/// The rules in order, then a form that adds one. A click on a rule edits it in place, as a click on a
/// vocabulary word does: Return, a click on another rule, or a click into the add form keeps the change,
/// Escape drops it, and an emptied Find removes the rule.
private struct ReplacementsSection: View {
    @Binding var replacements: [Replacement]
    @State private var new = Replacement(find: "", replacement: "")
    /// The rule being edited, and its unsaved changes. Not an optional rule, since a binding unwrapped
    /// from one crashes when the edit ends.
    @State private var editing: Replacement.ID?
    @State private var draft = Replacement(find: "", replacement: "")
    @FocusState private var focus: Field?

    private enum Field: Hashable { case newFind, newReplacement, editFind, editReplacement }

    var body: some View {
        Section("Replacements") {
            ForEach(replacements) { rule in
                if rule.id == editing {
                    form($draft, find: .editFind, replacement: .editReplacement) {
                        RemoveButton(title: "Remove") { remove(rule) }
                    }
                    .onSubmit(submitEdit)
                    .onExitCommand { editing = nil }
                } else {
                    ReplacementRow(rule: rule) {
                        commitEdit()
                        draft = rule
                        editing = rule.id
                        focus = .editFind
                    } remove: {
                        remove(rule)
                    }
                }
            }
            form($new, find: .newFind, replacement: .newReplacement) {
                Button("Add", action: add).disabled(!new.isValid)
            }
            .onSubmit(add)
            .onExitCommand { new = Replacement(find: "", replacement: "") }
        }
        // Focus also goes to nil on a click of the .* switch, which shouldn't end the edit.
        .onChange(of: focus) { if let focus, focus != .editFind, focus != .editReplacement { commitEdit() } }
    }

    /// The find and replace fields and the regular expression switch, for adding a rule or editing one.
    private func form(_ rule: Binding<Replacement>, find: Field, replacement: Field,
                      @ViewBuilder action: () -> some View) -> some View {
        ReplacementColumns {
            TextField("Find", text: rule.find)
                .settingsTextField()
                .focused($focus, equals: find)
        } replacement: {
            TextField("Replace with", text: rule.replacement)
                .settingsTextField()
                .focused($focus, equals: replacement)
        } pattern: {
            PatternToggle(isOn: rule.isPattern)
        } action: {
            action()
        }
        .settingsRowWarning(rule.wrappedValue.isPattern && !rule.wrappedValue.find.isEmpty && !rule.wrappedValue.isValid
            ? "Not a valid regular expression." : nil)
    }

    private func add() {
        guard new.isValid else { return }
        replacements.append(new)
        new = Replacement(find: "", replacement: "")
        focus = .newFind
    }

    private func remove(_ rule: Replacement) {
        if editing == rule.id { editing = nil }
        replacements.removeAll { $0.id == rule.id }
    }

    /// Return keeps editing an invalid pattern, so it can be fixed.
    private func submitEdit() {
        guard draft.find.isEmpty || draft.isValid else { return }
        commitEdit()
    }

    /// Ends editing. An emptied Find removes the rule, and an invalid pattern leaves the original.
    private func commitEdit() {
        guard let id = editing else { return }
        editing = nil
        guard let index = replacements.firstIndex(where: { $0.id == id }) else { return }
        if draft.find.isEmpty {
            replacements.remove(at: index)
        } else if draft.isValid {
            replacements[index] = draft
        }
    }
}

/// The columns every replacement row shares, whether it shows a rule, edits one, or adds one, so find,
/// arrow, replacement, the .* switch, and the trailing button line up from row to row. The trailing
/// columns keep the width of the switch and the Add button even in rows that show something smaller.
private struct ReplacementColumns<Find: View, Replacement: View, Pattern: View, Action: View>: View {
    @ViewBuilder let find: Find
    @ViewBuilder let replacement: Replacement
    @ViewBuilder let pattern: Pattern
    @ViewBuilder let action: Action

    var body: some View {
        HStack(spacing: 8) {
            find.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(SettingsColor.secondaryText)
            replacement.frame(maxWidth: .infinity, alignment: .leading)
            pattern.sized(like: PatternToggle(isOn: .constant(false)))
            action.sized(like: Button("Add") {})
        }
        // A text field's height, so a rule keeps its place when a click opens it.
        .frame(minHeight: 28)
        .padding(.vertical, 8)
    }
}

/// Switches a rule between plain text and a regular expression. The settings button style has no on
/// state, so the accent fill shows it.
private struct PatternToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(".*", isOn: $isOn)
            .toggleStyle(.button)
            .buttonStyle(SettingsButtonStyle(isProminent: isOn))
            .font(.system(.callout, design: .monospaced))
            .help(isOn
                ? "Regular expression. Use $1 in the replacement for the first group."
                : "Plain text, matching whole words and ignoring case. Click for a regular expression.")
    }
}

private struct ReplacementRow: View {
    let rule: Replacement
    let edit: () -> Void
    let remove: () -> Void
    @State private var isHovering = false
    /// Where the pointer was last seen over the row, in window coordinates.
    @State private var pointer: CGPoint?

    var body: some View {
        ReplacementColumns {
            text(rule.find)
        } replacement: {
            text(rule.replacement)
        } pattern: {
            if rule.isPattern {
                Text(".*").font(.system(.callout, design: .monospaced)).foregroundStyle(SettingsColor.secondaryText)
                    .help("Regular expression")
            }
        } action: {
            RemoveButton(title: "Remove", action: remove).opacity(isHovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        // The remove button shows once the pointer moves over the row. A rule added with Return appears
        // under the pointer, which macOS hides while typing, and plain hover would show its button there.
        .onContinuousHover(coordinateSpace: .global) { phase in
            switch phase {
            case .active(let location):
                if let pointer, pointer != location { isHovering = true }
                pointer = location
            case .ended:
                isHovering = false
                pointer = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Edit", edit)
        .accessibilityAction(named: "Remove", remove)
    }

    /// Inset like a text field's text, so a rule's text stays put when a click opens it for editing.
    private func text(_ value: String) -> some View {
        Text(value.isEmpty ? "Nothing" : value)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, SettingsTextField.textInset)
    }
}
