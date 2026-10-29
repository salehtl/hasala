import HasalaModels
import SwiftUI

/// A key on the amount keypad.
public enum AmountKey: Sendable, Hashable {
  case digit(Int)
  case decimal
  case delete
}

/// What has been typed on the amount keypad (page 11 · Behaviour). A pure value:
/// digits of any script, one decimal point, at most two decimals, leading zeros collapse ("007" is 7), at
/// most nine whole digits. Input that breaks a rule is ignored, so there is nothing to correct
/// afterwards. The amount is integer fils (`minor`); the text is display only.
public struct AmountEntry: Sendable, Hashable {
  /// The most whole digits an amount may have (999,999,999).
  public static let maxWholeDigits = 9

  /// The digits as typed, with at most one "." ("25000", "48.5", "0."). Never grouped.
  public private(set) var text: String

  public init() { text = "" }

  /// An entry typed as `text` would be, key by key (anything else is ignored).
  public init(typing text: String) {
    self.init()
    for ch in text {
      if MoneyFormat.isPoint(ch) {
        type(.decimal)
      } else if let d = MoneyFormat.typedDigit(ch) {
        type(.digit(d))
      }
    }
  }

  public static let maxMinor: Int64 = 999_999_999_99

  public static func clamped(_ minor: Int64) -> Int64 { min(max(0, minor), maxMinor) }

  public init(editing typed: String, previous: String, decimalSeparator: String) {
    let new = Array(typed)
    let old = Array(previous)
    let shared = min(new.count, old.count)
    var head = 0
    while head < shared, new[head] == old[head] { head += 1 }
    var tail = 0
    while tail < shared - head, new[new.count - 1 - tail] == old[old.count - 1 - tail] { tail += 1 }
    let inserted = head..<(new.count - tail)
    let commaIsPoint = decimalSeparator == ","
    self.init(typing: String(new.indices.map { i in commaIsPoint && inserted.contains(i) && new[i] == "," ? "." : new[i] }))
  }

  /// An entry showing a saved amount: whole units when there are no fils ("25000"), two
  /// decimals otherwise ("297.50").
  public init(minor: Int64) {
    let m = minor.magnitude
    let fils = m % 100
    text = fils == 0 ? "\(m / 100)" : "\(m / 100)." + (fils < 10 ? "0" : "") + "\(fils)"
  }

  /// True before anything is typed.
  public var isEmpty: Bool { text.isEmpty }

  /// True when the amount is 0 (the primary button stays disabled).
  public var isZero: Bool { (minor ?? 0) == 0 }

  private var parts: (whole: Substring, decimals: Substring?) {
    if let dot = text.firstIndex(of: ".") {
      return (text[..<dot], text[text.index(after: dot)...])
    }
    return (Substring(text), nil)
  }

  /// Applies one key. Delete removes one character.
  public mutating func type(_ key: AmountKey) {
    let (whole, decimals) = parts
    switch key {
    case .digit(let d):
      guard (0...9).contains(d) else { return }
      if let decimals {
        guard decimals.count < 2 else { return }  // a third decimal is ignored
        text.append(String(d))
      } else if whole == "0" {
        text = String(d)  // leading zeros collapse: "0" then "7" is 7, "0" then "0" stays 0
      } else {
        guard whole.count < Self.maxWholeDigits else { return }
        text.append(String(d))
      }
    case .decimal:
      guard decimals == nil else { return }  // a second point does nothing
      text = (whole.isEmpty ? "0" : String(whole)) + "."
    case .delete:
      if !text.isEmpty { text.removeLast() }
      if text == "0" { text = "" }
    }
  }

  /// Hold Delete: start again.
  public mutating func clear() { text = "" }

  /// The amount in fils, or nil before anything is typed. "12." is 1200, "12.5" is 1250.
  public var minor: Int64? {
    guard !text.isEmpty else { return nil }
    let (whole, decimals) = parts
    var units: Int64 = 0
    for ch in whole { units = units * 10 + Int64(ch.wholeNumberValue ?? 0) }
    var fils: Int64 = 0
    let dec = decimals.map(Array.init) ?? []
    if dec.count > 0 { fils += Int64(dec[0].wholeNumberValue ?? 0) * 10 }
    if dec.count > 1 { fils += Int64(dec[1].wholeNumberValue ?? 0) }
    return units * 100 + fils
  }

  /// The figure as shown: thousands get commas as you type ("25,000"); a typed point and
  /// decimals stay as typed ("48.5", "12."). "0" before anything is typed.
  public var display: String {
    let (whole, decimals) = parts
    let units = UInt64(whole) ?? 0
    let grouped = whole.isEmpty ? "0" : MoneyFormat.grouped(units)
    return decimals.map { grouped + "." + $0 } ?? grouped
  }

  /// What VoiceOver reads for the figure: "48 dirhams", "25,000 dirhams".
  public func spoken(unit: String = "AED") -> String {
    unit == "AED" ? "\(display) dirhams" : "\(unit) \(display)"
  }
}

/// The app's number pad for money (page 11 · Amount keypad): twelve keys, 1-2-3 on top, the
/// decimal and Delete either side of 0. Docked at the bottom of a one-amount screen, or inline
/// in a sheet. A pressed key takes the tray colour for the touch with a light tick; the keypad
/// never slides in or out. Hold Delete to clear.
public struct AmountKeypad: View {
  public enum Layout: Sendable { case docked, inline }

  @Binding var entry: AmountEntry
  let layout: Layout
  let compact: Bool
  /// Counts key presses, so the haptic plays once per key.
  @State private var presses = 0

  public init(entry: Binding<AmountEntry>, layout: Layout = .docked, compact: Bool = false) {
    _entry = entry
    self.layout = layout
    self.compact = compact
  }

  private static let rows: [[AmountKey]] = [
    [.digit(1), .digit(2), .digit(3)],
    [.digit(4), .digit(5), .digit(6)],
    [.digit(7), .digit(8), .digit(9)],
    [.decimal, .digit(0), .delete],
  ]

  public var body: some View {
    VStack(spacing: layout == .docked && !compact ? 8 : 6) {
      ForEach(Array(Self.rows.enumerated()), id: \.offset) { _, row in
        HStack(spacing: 6) {
          ForEach(row, id: \.self) { key in
            KeypadKey(key: key, layout: layout, compact: compact) {
              entry.type(key)
              presses += 1
            } onClear: {
              entry.clear()
              presses += 1
            }
          }
        }
      }
    }
    .padding(.top, layout == .docked ? 8 : 6)
    .padding(.horizontal, 6)
    // Docked, the tray runs under the home indicator; 46 below the keys in all (page 11).
    .padding(.bottom, layout == .docked ? 12 : 6)
    .background {
      if layout == .docked {
        HColor.keypadTray.ignoresSafeArea(edges: .bottom)
      } else {
        RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous).fill(HColor.keypadTrayInline)
      }
    }
    // Digits keep 28 at every text size (fixed faces); the figure above is what grows.
    .hHaptic(.keyTick, trigger: presses)
  }
}

struct KeypadKey: View {
  let key: AmountKey
  let layout: AmountKeypad.Layout
  var compact = false
  let action: () -> Void
  let onClear: () -> Void

  var body: some View {
    Button(action: action) {
      label
        .frame(maxWidth: .infinity, minHeight: height)
        .contentShape(Rectangle())
    }
    .buttonStyle(KeypadKeyStyle(tile: hasTile, layout: layout))
    .simultaneousGesture(
      LongPressGesture(minimumDuration: 0.5).onEnded { _ in if key == .delete { onClear() } }
    )
    .accessibilityLabel(spoken)
    .accessibilityIdentifier(identifier)
  }

  private var height: CGFloat {
    layout == .docked && !compact ? HSpacing.keypadKeyHeight : HSpacing.keypadKeyHeightInline
  }

  private var hasTile: Bool {
    if case .digit = key { return true }
    return false
  }

  @ViewBuilder private var label: some View {
    switch key {
    // Digits keep 28 at every text size on purpose (page 11); the figure above is what grows.
    // The marker tells the accessibility audit the fixed size is deliberate.
    case .digit(let d):
      Text("\(d)")
        .font(.system(size: HFontSize.numericMedium, weight: .medium, design: .rounded))
        .foregroundStyle(HColor.textPrimary)
        .accessibilityIdentifier(hasalaCappedFigureIdentifier)
    case .decimal:
      Text(verbatim: ".")
        .font(.system(size: HFontSize.numericMedium, weight: .medium, design: .rounded))
        .foregroundStyle(HColor.textPrimary)
        .accessibilityIdentifier(hasalaCappedFigureIdentifier)
    case .delete:
      HIconView(.delete, size: 26, color: HColor.iconPrimary)
    }
  }

  private var spoken: String {
    switch key {
    case .digit(let d): "\(d)"
    case .decimal: "Decimal point"
    case .delete: "Delete"
    }
  }

  private var identifier: String {
    switch key {
    case .digit(let d): "keypad.\(d)"
    case .decimal: "keypad.decimal"
    case .delete: "keypad.delete"
    }
  }
}

/// A digit key is a white tile with a 1 pt bottom shadow that takes the tray colour while
/// pressed; the decimal and Delete keys have no tile, so the digits stand out.
struct KeypadKeyStyle: ButtonStyle {
  let tile: Bool
  let layout: AmountKeypad.Layout

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    let shape = RoundedRectangle(cornerRadius: HRadius.control, style: .continuous)
    configuration.label
      .background {
        if tile {
          shape
            .fill(pressed ? (layout == .docked ? HColor.keypadTray : HColor.keypadTrayInline) : HColor.keypadKey)
            .shadow(color: .black.opacity(pressed ? 0 : (layout == .docked ? 0.07 : 0.10)), radius: 0, x: 0, y: 1)
        }
      }
      .animation(.easeOut(duration: HMotion.highlight), value: pressed)
  }
}
