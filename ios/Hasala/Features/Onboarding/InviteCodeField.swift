import HasalaDesign
import SwiftUI
import UIKit

/// The invite code field (Paper page 14, section 14.1; spec 04 §6.1.4).
///
/// A UIKit text view rather than a SwiftUI `TextField`: it takes each edit as UIKit
/// delivers it, applies it through `InviteCodeEntry`, and sets the grouped text and the
/// caret itself before the next key arrives. A `TextField` regrouped from `onChange`
/// wrote its text back a render pass later, after more keys had landed at a caret the
/// rewrite then moved, so fast typing came out reordered ("ABCD-EGHI-FJKL-…").
struct InviteCodeField: UIViewRepresentable {
  static let placeholder = "ABCD-EFGH-IJKL-MNOP-QRST-UVWX"

  /// The code characters (`InviteCode.entryCharacters`); the field shows them grouped.
  @Binding var text: String
  @Binding var focused: Bool
  var identifier: String
  /// A pasted `https://hasala.app/i/<CODE>#<KEY>`.
  var onLink: (InviteLink) -> Void

  func makeUIView(context: Context) -> InviteCodeTextView {
    let v = InviteCodeTextView()
    // Subheadline, monospaced, semibold, scaled with Dynamic Type.
    let size = UIFont.preferredFont(forTextStyle: .subheadline,
                                    compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
    let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .monospacedSystemFont(ofSize: size, weight: .semibold))
    v.font = font
    v.adjustsFontForContentSizeCategory = true
    v.placeholderLabel.font = font
    v.placeholderLabel.adjustsFontForContentSizeCategory = true
    v.placeholderLabel.text = Self.placeholder
    v.placeholderLabel.textColor = .placeholderText
    v.textColor = UIColor(HColor.fieldText)
    v.tintColor = UIColor(HColor.actionAccent)
    v.keyboardType = .asciiCapable
    v.returnKeyType = .done
    v.autocapitalizationType = .allCharacters
    v.autocorrectionType = .no
    v.spellCheckingType = .no
    v.smartQuotesType = .no
    v.smartDashesType = .no
    v.smartInsertDeleteType = .no
    v.inlinePredictionType = .no
    v.mathExpressionCompletionType = .no
    v.writingToolsBehavior = .none
    v.textContentType = nil
    v.accessibilityLabel = "Invite code"
    v.accessibilityIdentifier = identifier
    v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    v.delegate = context.coordinator
    v.show(InviteCodeEntry(text).text)
    return v
  }

  func updateUIView(_ v: InviteCodeTextView, context: Context) {
    context.coordinator.parent = self
    // Set from outside the field (the Paste button, an invite link): caret at the end.
    let entry = InviteCodeEntry(text)
    if v.text != entry.text {
      v.show(entry.text)
      v.selectedRange = NSRange(location: entry.textCaret, length: 0)
    }
  }

  /// The width offered, and the height the text (or, while empty, the placeholder) wraps
  /// to there, so the code reflows at large text sizes instead of clipping; never less
  /// than a tap target.
  func sizeThatFits(_ proposal: ProposedViewSize, uiView v: InviteCodeTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    return CGSize(width: width, height: v.fittingHeight(width: width))
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: InviteCodeField

    init(_ parent: InviteCodeField) { self.parent = parent }

    func textView(_ v: UITextView, shouldChangeTextIn range: NSRange, replacementText string: String) -> Bool {
      if string == "\n" {
        v.resignFirstResponder()
        return false
      }
      if string.count > 1, let link = InviteLink.parse(pasted: string) {
        parent.onLink(link)
        return false
      }
      let caret = v.selectedRange
      let forward = string.isEmpty && caret.length == 0 && caret.location == range.location
      apply(InviteCodeEntry.edit(v.text, range: range, replacement: string, forward: forward), to: v)
      return false
    }

    /// A change UIKit made without asking first (dictation, for one): regrouped where the
    /// caret is.
    func textViewDidChange(_ v: UITextView) {
      let caret = NSRange(location: NSMaxRange(v.selectedRange), length: 0)
      apply(InviteCodeEntry.edit(v.text, range: caret, replacement: ""), to: v)
    }

    func textViewDidBeginEditing(_ v: UITextView) { parent.focused = true }

    func textViewDidEndEditing(_ v: UITextView) { parent.focused = false }

    private func apply(_ entry: InviteCodeEntry, to v: UITextView) {
      if v.text != entry.text { (v as? InviteCodeTextView)?.show(entry.text) }
      v.selectedRange = NSRange(location: entry.textCaret, length: 0)
      if parent.text != entry.characters { parent.text = entry.characters }
    }
  }
}

/// A text view that wraps instead of scrolling, and shows a placeholder while empty. It is
/// at least 44 points tall with its text centred, so the whole of it takes a tap.
final class InviteCodeTextView: UITextView {
  static let minimumHeight: CGFloat = 44
  let placeholderLabel = UILabel()

  init() {
    super.init(frame: .zero, textContainer: nil)
    backgroundColor = .clear
    isScrollEnabled = false
    textContainerInset = .zero
    textContainer.lineFragmentPadding = 0
    placeholderLabel.numberOfLines = 0
    placeholderLabel.isAccessibilityElement = false
    addSubview(placeholderLabel)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  /// Replaces the text (never through the keyboard: `shouldChangeTextIn` refuses its edits
  /// and applies them here).
  func show(_ text: String) {
    self.text = text
    placeholderLabel.isHidden = !text.isEmpty
    invalidateIntrinsicContentSize()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let top = max(0, floor((bounds.height - contentHeight(width: bounds.width)) / 2))
    if textContainerInset.top != top { textContainerInset = UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0) }
    placeholderLabel.isHidden = !text.isEmpty
    let height = placeholderLabel.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
    placeholderLabel.frame = CGRect(x: 0, y: top, width: bounds.width, height: height)
  }

  /// The height for `width`: the content's, and at least `minimumHeight`.
  func fittingHeight(width: CGFloat) -> CGFloat {
    ceil(max(Self.minimumHeight, contentHeight(width: width)))
  }

  /// The text wrapped to `width` (while empty, the placeholder), without the centring inset.
  private func contentHeight(width: CGFloat) -> CGFloat {
    let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
    let own = sizeThatFits(fit).height - textContainerInset.top - textContainerInset.bottom
    return text.isEmpty ? max(own, placeholderLabel.sizeThatFits(fit).height) : own
  }
}
