import HasalaDesign
import SwiftUI
import UIKit

struct SetAsideSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var contentHeight: CGFloat?

  static let title = "Hasala set a change aside"
  static let message =
    "A change from your account didn't open on this iPhone, so Hasala left it out. Everything else keeps syncing."
  static let codeLead = "If it happens again, email \(BuildSurface.supportEmail) and mention this code"
  static let code = "integrityAlarm"

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(spacing: 16) {
          Circle()
            .fill(HColor.posterGlyph)
            .frame(width: 72, height: 72)
            .overlay { HIconView(.alert, size: 32, color: HColor.statusWarningForeground, strokeWidth: 2.2) }
            .accessibilityHidden(true)
          VStack(spacing: 8) {
            Text(Self.title)
              .hType(.largeTitle)
              .foregroundStyle(HColor.textPrimary)
              .frame(maxWidth: 250)
              .accessibilityAddTraits(.isHeader)
              .accessibilityIdentifier("setAside.title")
            Text(Self.message)
              .hType(.body)
              .foregroundStyle(HColor.textOnWashSecondary)
              .frame(maxWidth: 320)
              .accessibilityIdentifier("setAside.message")
          }
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 40)
        SupportCodeChip(lead: Self.codeLead, code: Self.code, identifier: "setAside.code")
          .padding(.horizontal, HSpacing.insetPage)
          .padding(.top, 52)
        Button("OK") { dismiss() }
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("setAside.ok")
          .padding(.horizontal, HSpacing.insetPage)
          .padding(.top, 64)
          .padding(.bottom, 34)
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .ignoresSafeArea(.container, edges: .bottom)
    .background(alignment: .top) {
      Rectangle()
        .fill(
          .linearGradient(
            Gradient(colors: [HColor.hueSandStart, HColor.hueSandStart.opacity(0)]).colorSpace(.perceptual),
            startPoint: .top, endPoint: .bottom))
        .frame(height: 360)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
    .background(HColor.surfaceSecondary)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("setAside")
    .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(contentHeight ?? 560)])
    .presentationCornerRadius(HRadius.sheetLarge)
    .presentationBackground(HColor.surfaceSecondary)
    .presentationDragIndicator(.visible)
  }
}

struct SupportCodeChip: View {
  let lead: String
  let code: String
  let identifier: String
  @State private var copied = false
  @ScaledMetric(relativeTo: .subheadline) private var codeSize: CGFloat = 14

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(lead)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Text(verbatim: code)
          .font(.system(size: codeSize, design: .monospaced))
          .foregroundStyle(HColor.textPrimary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier(identifier)
        Button {
          UIPasteboard.general.string = code
          copied = true
        } label: {
          HStack(spacing: 6) {
            HIconView(.copy, size: 16, color: HColor.iconPrimary)
              .frame(width: 16, height: 16)
              .accessibilityHidden(true)
            Text(copied ? "Copied" : "Copy")
              .hType(.subheadline.weight(.semibold))
              .foregroundStyle(HColor.textPrimary)
          }
          .padding(.horizontal, 12)
          .frame(minHeight: 36)
          .background(HColor.surfaceSecondary, in: Capsule())
          .contentShape(Capsule())
        }
        .buttonStyle(HRowPressStyle())
        .accessibilityLabel(copied ? "Copied" : "Copy code")
        .accessibilityIdentifier("\(identifier).copy")
      }
      .padding(.leading, 14)
      .padding(.trailing, 4)
      .padding(.vertical, 4)
      .frame(minHeight: 44)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
