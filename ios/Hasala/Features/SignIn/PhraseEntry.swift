import HasalaDesign
import SwiftUI
import UIKit

/// The 12 words as typed into the entry grid (Paper "RecoveryPhraseGrid · Entry", GDD):
/// one string, read as cells. Lower-case letters and single spaces only, at most 12 words;
/// the word being typed is the one after the last space. Pure, so the rules are tested.
struct PhraseEntryState: Equatable {
  static let wordCount = 12

  let text: String

  init(_ text: String) {
    self.text = Self.normalised(text)
  }

  /// What the field keeps of what was typed or pasted: letters in lower case, one space
  /// between words, no space in front, nothing past the twelfth word.
  static func normalised(_ raw: String) -> String {
    var out = ""
    var words = 0
    var inWord = false
    for ch in raw.lowercased() {
      if ch.isASCII, ch.isLetter {
        if !inWord {
          if words == wordCount { break }
          words += 1
          inWord = true
        }
        out.append(ch)
      } else if ch.isNumber {
        // A numbered paste ("1. orbit 2. canvas"): the numbers are the paper's, not words.
        continue
      } else if inWord {
        // Spaces, new lines, commas and full stops all end a word.
        inWord = false
        if words == wordCount { break }
        out.append(" ")
      }
    }
    // The twelfth word takes no space after it: there is no cell to move to.
    if words == wordCount, out.hasSuffix(" ") { out.removeLast() }
    return out
  }

  var words: [String] { text.split(separator: " ").map(String.init) }

  private var endsWithSpace: Bool { text.hasSuffix(" ") }

  /// The cell the next letter goes into, 0-based (11 once the twelfth word has started).
  var activeIndex: Int {
    guard !text.isEmpty else { return 0 }
    return min(endsWithSpace ? words.count : words.count - 1, Self.wordCount - 1)
  }

  /// The word in the active cell so far ("sad").
  var current: String {
    guard !endsWithSpace, let last = words.last else { return "" }
    return last
  }

  /// Words whose cell is done: everything before the active cell, and the twelfth once it
  /// is a list word.
  var finished: Int {
    let before = endsWithSpace ? words.count : max(0, words.count - 1)
    if words.count == Self.wordCount, PhraseRules.isWord(current) { return Self.wordCount }
    return before
  }

  /// The first finished word that isn't on the recovery list (its cell gets the ring).
  var unknownIndex: Int? {
    words.prefix(finished).firstIndex { !PhraseRules.isWord($0) }
  }

  var isComplete: Bool { finished == Self.wordCount && unknownIndex == nil }

  /// Up to three list words for the active cell, the typed word itself first when it is
  /// one (Paper: "sad" · "saddle" · "sadness").
  var suggestions: [String] {
    let found = PhraseRules.suggestions(for: current, limit: 4)
    guard !found.isEmpty else { return [] }
    var out = PhraseRules.isWord(current) ? [current] : []
    for w in found where w != current && out.count < 3 { out.append(w) }
    return out
  }

  /// The text with the active word replaced by `word`, moving on to the next cell.
  func completing(with word: String) -> String {
    var ws = words
    if !endsWithSpace, !ws.isEmpty { ws.removeLast() }
    ws.append(word)
    return Self.normalised(ws.joined(separator: " ") + " ")
  }
}

/// The 12-word entry (Paper GDD, GZT): one hidden field drawn as two columns of six
/// numbered cells in a white card (one column at the accessibility sizes). The active cell
/// turns white with an inset ring, a blue number and a caret; a word not on the list rings
/// its own cell. Suggestions come only from the recovery word list, in a bar over the
/// keyboard; the keyboard neither corrects nor learns. "Paste" is the system paste button,
/// so iOS reads the clipboard once, on the person's tap, without a prompt; whoever accepts
/// the words clears it with `clearPastedPhrase(changeCount:)`.
struct PhraseEntryGrid: View {
  @Binding var text: String
  /// The pasteboard's `changeCount` when a paste landed here (nil until one does).
  @Binding var pastedChangeCount: Int?
  var identifier = "phraseEntry.field"
  /// Return on the twelfth word.
  var onSubmit: () -> Void = {}

  @FocusState private var focused: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  private var state: PhraseEntryState { PhraseEntryState(text) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ZStack {
        field
        cells
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
      .onTapGesture { focused = true }
      .environment(\.layoutDirection, .leftToRight)
      if let unknown = state.unknownIndex {
        FieldErrorLine(text: "Word \(unknown + 1) isn't on the recovery list. Check the spelling on your paper.")
          .accessibilityIdentifier("phraseEntry.unknown")
      }
      helper
    }
    .onAppear { focused = true }
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        SuggestionBar(words: state.suggestions) { text = state.completing(with: $0) }
      }
    }
  }

  private var field: some View {
    TextField("", text: Binding(get: { text }, set: { new in
      let before = text
      text = PhraseEntryState.normalised(new)
      // A jump of many letters at once is a paste. Only `changeCount` is read: reading the
      // contents would show iOS's paste prompt.
      if new.count - before.count >= 12 { pastedChangeCount = UIPasteboard.general.changeCount }
    }))
    .textContentType(nil)
    .keyboardType(.asciiCapable)
    .autocorrectionDisabled()
    .textInputAutocapitalization(.never)
    .submitLabel(state.finished >= PhraseEntryState.wordCount - 1 ? .done : .next)
    .onSubmit {
      if state.isComplete {
        onSubmit()
      } else {
        // Return moves on, as "next" says.
        if !state.current.isEmpty { text = PhraseEntryState.normalised(text + " ") }
        focused = true
      }
    }
    .focused($focused)
    .foregroundStyle(.clear)
    .tint(.clear)
    .frame(maxWidth: .infinity)
    .accessibilityIdentifier(identifier)
    .accessibilityLabel("Word \(state.activeIndex + 1)")
    .accessibilityValue(state.current)
    .accessibilityHint("Your recovery phrase, \(state.finished) of 12 words.")
  }

  private var cells: some View {
    let columns = typeSize.isAccessibilitySize ? 1 : 2
    let perColumn = PhraseEntryState.wordCount / columns
    let words = state.words
    return HStack(alignment: .top, spacing: 8) {
      ForEach(0..<columns, id: \.self) { c in
        VStack(spacing: 6) {
          ForEach(0..<perColumn, id: \.self) { r in
            let i = c * perColumn + r
            cell(i, word: i < words.count ? words[i] : "")
          }
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(12)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  @ScaledMetric(relativeTo: .callout) private var caretHeight: CGFloat = 20

  private func cell(_ i: Int, word: String) -> some View {
    let active = focused && i == state.activeIndex && !(state.isComplete && i == PhraseEntryState.wordCount - 1)
    let unknown = state.unknownIndex == i
    let filled = !word.isEmpty
    return HStack(spacing: 8) {
      Text("\(i + 1)")
        .hFigure(HFigure(size: 13, leading: 18, weight: active ? .bold : .semibold, textStyle: .footnote))
        .foregroundStyle(active ? HColor.textLink : filled ? HColor.textSecondary : HColor.neutral400)
        .frame(minWidth: 18, alignment: .trailing)
      HStack(spacing: 1) {
        Text(word)
          .hType(HType(size: 16, leading: 22, weight: .medium, textStyle: .callout))
          .foregroundStyle(HColor.textPrimary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        if active {
          RoundedRectangle(cornerRadius: 1).fill(HColor.actionAccent).frame(width: 2, height: caretHeight)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(minHeight: 38)
    .background(active ? HColor.surfacePrimary : HColor.surfaceSecondary,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      // Entry cells ring inside their edge (page 11 known drift: code cells ring outside).
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(unknown ? HColor.fieldError : HColor.fieldFocus, lineWidth: 2)
        .opacity(active || unknown ? 1 : 0)
    }
  }

  private var helper: some View {
    HStack(alignment: .center, spacing: 12) {
      Text("Suggestions come from the recovery word list, never your keyboard history.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      PasteButton(payloadType: String.self) { pasted in
        Task { @MainActor in paste(pasted.first ?? "") }
      }
      .labelStyle(.titleOnly)
      .buttonBorderShape(.capsule)
      .tint(HColor.surfacePrimary)
      .accessibilityIdentifier("phraseEntry.paste")
    }
    .padding(.horizontal, 4)
  }

  /// "Paste": fills from the first cell (page 11 §05).
  private func paste(_ pasted: String) {
    text = PhraseEntryState.normalised(pasted)
    pastedChangeCount = UIPasteboard.general.changeCount
    focused = true
  }
}

/// The word-list suggestions over the keyboard (Paper "Suggestions (phrase words only)"):
/// three slots split by hairlines, the middle one (or the only one) in a white pill.
private struct SuggestionBar: View {
  let words: [String]
  let pick: (String) -> Void

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(words.enumerated()), id: \.element) { i, w in
        if i > 0 {
          Rectangle().fill(HColor.appleLabelsPrimary.opacity(0.16)).frame(width: 1, height: 24)
            .accessibilityHidden(true)
        }
        let picked = i == (words.count == 3 ? 1 : 0)
        Button { pick(w) } label: {
          Text(w)
            .font(.system(size: 17, weight: picked ? .semibold : .regular))
            .foregroundStyle(HColor.appleLabelsPrimary)
            .padding(.horizontal, 18)
            .frame(minHeight: 34)
            .background(picked ? HColor.white : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use \(w)")
        .accessibilityIdentifier("phraseEntry.suggestion.\(w)")
      }
    }
    .frame(maxWidth: .infinity)
  }
}

/// After a pasted phrase is accepted, clear the pasteboard if it still holds that paste
/// (spec 04 §6.7). Nothing is read from it: an unchanged `changeCount` means the same
/// contents, and writing never shows iOS's paste prompt. A typed phrase leaves the
/// pasteboard alone.
@MainActor
func clearPastedPhrase(changeCount: Int?) {
  guard let changeCount else { return }
  let pb = UIPasteboard.general
  if pb.changeCount == changeCount { pb.items = [] }
}
