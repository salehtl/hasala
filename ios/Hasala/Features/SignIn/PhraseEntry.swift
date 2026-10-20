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

  /// What each cell draws: the words, or dots in place of each word while masked.
  func drawn(masked: Bool) -> [String] {
    masked ? words.map { _ in "•••••" } : words
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
///
/// Paper draws no button under the grid: Return moves to the next cell and sends the
/// twelfth, and the word-list suggestions sit on the keyboard. The screen owns `focused`,
/// so while the keyboard is up its dock holds `PhraseSuggestions` (it rides on the
/// keyboard), and its button once the keyboard goes. The screen also applies
/// `revealsPhraseEntry(_:)`, so the title, the grid, the helper and Paste stay in sight
/// above that bar.
struct PhraseEntryGrid: View {
  /// Each cell, for `revealsPhraseEntry(_:)` at the accessibility sizes.
  static func cellID(_ index: Int) -> String { "phraseEntry.cell.\(index)" }

  @Binding var text: String
  /// The pasteboard's `changeCount` when a paste landed here (nil until one does).
  @Binding var pastedChangeCount: Int?
  var focused: FocusState<Bool>.Binding
  var identifier = "phraseEntry.field"
  /// Return on the twelfth word.
  var onSubmit: () -> Void = {}

  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.phraseEntryCompact) private var compact
  @Environment(\.scenePhase) private var scenePhase
  @State private var captured = screenIsCaptured()
  @State private var screenshotWarning = false

  private var state: PhraseEntryState { PhraseEntryState(text) }
  private var masked: Bool { captured || scenePhase != .active }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ZStack {
        field
        cells
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
      .onTapGesture { focused.wrappedValue = true }
      .environment(\.layoutDirection, .leftToRight)
      if captured {
        Text("Your words stay hidden. \(PhraseGrid.maskedNote)")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("phraseEntry.masked")
      }
      if screenshotWarning {
        FailureBanner(failure: .badPhrase("That screenshot holds your recovery phrase. Delete it from Photos, and from Recently Deleted."))
      }
      if let unknown = state.unknownIndex {
        FieldErrorLine(text: "Word \(unknown + 1) isn't on the recovery list. Check the spelling on your paper.")
          .accessibilityIdentifier("phraseEntry.unknown")
      }
      helper
    }
    .privacySensitive()
    .onAppear {
      focused.wrappedValue = true
      captured = screenIsCaptured()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
      captured = screenIsCaptured()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
      screenshotWarning = !text.isEmpty && !captured
    }
    .task {
      for _ in 0..<12 {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, text.isEmpty, !focused.wrappedValue else { return }
        focused.wrappedValue = true
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
        focused.wrappedValue = true
      }
    }
    .focused(focused)
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
    let words = state.drawn(masked: masked)
    return HStack(alignment: .top, spacing: 8) {
      ForEach(0..<columns, id: \.self) { c in
        VStack(spacing: compact ? 4 : 6) {
          ForEach(0..<perColumn, id: \.self) { r in
            let i = c * perColumn + r
            cell(i, word: i < words.count ? words[i] : "")
              .id(Self.cellID(i))
          }
        }
        .frame(maxWidth: .infinity)
      }
    }
    .padding(compact ? 8 : 12)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  @ScaledMetric(relativeTo: .callout) private var caretHeight: CGFloat = 20

  private func cell(_ i: Int, word: String) -> some View {
    let active = focused.wrappedValue && i == state.activeIndex && !(state.isComplete && i == PhraseEntryState.wordCount - 1)
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
    .frame(minHeight: compact ? 32 : 38)
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
    focused.wrappedValue = true
  }
}

extension EnvironmentValues {
  /// The keyboard is up at a standard text size (`revealsPhraseEntry`): the grid sets its
  /// cells 32 tall, 4 apart, in an 8 pt card, so with the system keyboard (taller than
  /// Paper's, with the suggestion bar above it) the title still fits over the entry.
  @Entry var phraseEntryCompact = false
}

extension View {
  /// Keeps the 12-word entry in sight above its screen's dock, under its title (Paper GDD,
  /// GZT draw the title, the grid, the helper and Paste clear of the keyboard). The
  /// suggestion bar sits over the keyboard, and the system keyboard is taller than Paper's,
  /// so while it is up the grid tightens (`phraseEntryCompact`), and the page scrolls the
  /// least that shows the whole screen body (`accountScreenBodyID`: the question, the grid,
  /// the helper with Paste, and a failure under them) above the bar. Where all of it can't
  /// fit (larger text, a smaller iPhone, a failure line), the body's top goes to the top of
  /// the room instead: the title is never scrolled under the header, and the rest scrolls
  /// (as the words go in, the page moves only as far as the cell being typed needs). At the
  /// accessibility sizes the grid is one long column, so the active cell is kept in the
  /// middle instead, as the words go in.
  func revealsPhraseEntry(_ text: String) -> some View {
    let state = PhraseEntryState(text)
    return modifier(PhraseEntryReveal(activeIndex: state.activeIndex, unknownIndex: state.unknownIndex))
  }
}

private struct PhraseEntryReveal: ViewModifier {
  let activeIndex: Int
  /// A word off the list adds its line under the grid: the block grows, so it is shown again.
  let unknownIndex: Int?
  @Environment(\.hMotion) private var motion
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var keyboardUp = false
  /// The screen body fits between the header and the dock (its 16 pt foot aside).
  @State private var bodyFits = true

  func body(content: Content) -> some View {
    ScrollViewReader { proxy in
      content
        .environment(\.phraseEntryCompact, keyboardUp && !typeSize.isAccessibilitySize)
        .onScrollGeometryChange(for: Bool.self) { g in
          g.contentSize.height - 16 <= g.containerSize.height - g.contentInsets.top - g.contentInsets.bottom + 0.5
        } action: { _, fits in
          bodyFits = fits
          if keyboardUp { reveal(proxy) }
        }
        .onGeometryChange(for: Bool.self) { $0.safeAreaInsets.bottom > 120 } action: { up in
          withAnimation(motion.animation(.fade)) { keyboardUp = up }
          // After the tighter grid is laid out.
          if up { Task { reveal(proxy) } }
        }
        .onChange(of: activeIndex) {
          // Where the body doesn't all fit, the cell being typed is kept in sight too.
          guard keyboardUp, typeSize.isAccessibilitySize || !bodyFits else { return }
          withAnimation(motion.animation(.fade)) {
            proxy.scrollTo(PhraseEntryGrid.cellID(activeIndex), anchor: typeSize.isAccessibilitySize ? .center : nil)
          }
        }
        .onChange(of: unknownIndex) {
          // After the line is laid out.
          if keyboardUp { Task { reveal(proxy) } }
        }
    }
  }

  private func reveal(_ proxy: ScrollViewProxy) {
    withAnimation(motion.animation(.fade)) {
      if typeSize.isAccessibilitySize {
        proxy.scrollTo(PhraseEntryGrid.cellID(activeIndex), anchor: .center)
      } else if bodyFits {
        // No anchor: the least scroll that shows the whole body.
        proxy.scrollTo(accountScreenBodyID)
      } else {
        // Its top at the top of the room, so the title stays below the header.
        proxy.scrollTo(accountScreenBodyID, anchor: .top)
      }
    }
  }
}

/// The word-list suggestions on the keyboard (Paper "Suggestions (phrase words only)"), for
/// an entry screen's dock while the grid is focused: a 44 glass bar of three slots split
/// by hairlines, the middle one (or the only one) in a white pill. Only recovery-list words
/// are offered; picking one fills the cell and moves on. Before a letter is typed the bar
/// says which cell is next, so it doesn't come and go with each word.
struct PhraseSuggestions: View {
  @Binding var text: String

  var body: some View {
    let state = PhraseEntryState(text)
    SuggestionBar(words: state.suggestions, cell: state.activeIndex + 1) { text = state.completing(with: $0) }
      .frame(maxWidth: .infinity, minHeight: 44)
      .hGlass(in: Capsule())
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("phraseEntry.suggestions")
  }
}

private struct SuggestionBar: View {
  let words: [String]
  /// The active cell, 1-based.
  let cell: Int
  let pick: (String) -> Void

  var body: some View {
    HStack(spacing: 0) {
      if words.isEmpty {
        Text("Word \(cell) of 12")
          .font(.body)
          .foregroundStyle(HColor.appleLabelsSecondary)
          .lineLimit(1)
          .padding(.horizontal, 18)
          .frame(maxWidth: .infinity, minHeight: 44)
          .accessibilityHidden(true)
      }
      ForEach(Array(words.enumerated()), id: \.element) { i, w in
        if i > 0 {
          Rectangle().fill(HColor.appleLabelsPrimary.opacity(0.16)).frame(width: 1, height: 24)
            .accessibilityHidden(true)
        }
        let picked = i == (words.count == 3 ? 1 : 0)
        Button { pick(w) } label: {
          Text(w)
            .font(.body.weight(picked ? .semibold : .regular))
            .foregroundStyle(HColor.appleLabelsPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 16)
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
    .padding(.horizontal, 6)
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
