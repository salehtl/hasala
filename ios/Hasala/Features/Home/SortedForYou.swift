import HasalaDesign
import HasalaModels
import SwiftUI

struct SortedForYouRow: View {
  let line: String
  let spoken: String
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(spacing: 12) {
        Circle().fill(HColor.statusSuccessSurface).frame(width: 32, height: 32)
          .overlay { HIconView(.check, size: 16, color: HColor.statusSuccessForeground, strokeWidth: 2.2) }
        Text(line)
          .hType(.subheadline.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        HStack(spacing: 4) {
          Text("Look").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textLink)
          HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.textLink)
        }
        .frame(minHeight: HSpacing.targetMinimum)
      }
      .padding(.vertical, 10)
      .padding(.leading, 14)
      .padding(.trailing, 12)
      .frame(minHeight: 56)
      .background {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(HColor.widgetSurface)
          .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
          .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
    .accessibilityHint("Opens Sorted for you")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("home.sortedForYou")
  }
}

struct SortedForYouView: View {
  @Bindable var app: AppModel
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let snapshot = app.sortedForYou
    PushedPage(app: app, title: "Sorted for you", spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Last 7 days").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textSecondary)
        Text(SortedForYouSnapshot.intro)
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, HSpacing.insetPage)
      if snapshot.isEmpty {
        Text(SortedForYouSnapshot.emptyLine)
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .frame(maxWidth: .infinity, alignment: .center)
          .padding(24)
          .background(surface(26))
          .padding(.horizontal, HSpacing.insetPage)
          .accessibilityIdentifier("sortedForYou.empty")
      } else {
        ForEach(snapshot.items) { item in
          batch(item).padding(.horizontal, HSpacing.insetPage)
        }
      }
      Text(SortedForYouSnapshot.footnote)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, HSpacing.insetPage)
    }
  }

  private func batch(_ item: SortedForYouItem) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(item.overline)
          .hType(.overline)
          .foregroundStyle(HColor.textSecondary)
        Text(item.title)
          .hType(.headline)
          .foregroundStyle(HColor.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(item.spokenHeader)
      .accessibilityAddTraits(.isHeader)
      let links = Group {
        link(item.undoAllLabel, id: "sortedForYou.undoAll.\(item.id)") { app.perform(item.undoAll) }
        if item.canStopRule, let rule = item.ruleID {
          link("Stop this rule", id: "sortedForYou.stopRule.\(item.id)") { app.perform(.stopRule(rule)) }
        }
      }
      Group {
        if typeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 0) { links }
        } else {
          HStack(spacing: 16) { links }
        }
      }
      .padding(.top, 4)
      HColor.borderSubtle.frame(height: 1).padding(.top, 8).accessibilityHidden(true)
      ForEach(Array(item.txnIDs.enumerated()), id: \.element) { i, id in
        if i > 0 { HColor.borderSubtle.frame(height: 1).padding(.leading, 44).accessibilityHidden(true) }
        if let t = app.store.state.txn(id) { row(t, item) }
      }
    }
    .padding(.top, 16)
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
    .background(surface(26))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("sortedForYou.batch.\(item.id)")
  }

  private func row(_ t: Txn, _ item: SortedForYouItem) -> some View {
    let category = app.store.state.category(t.categoryID)
    let text = VStack(alignment: .leading, spacing: 2) {
      Text(t.merchant).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 0) {
        Text("\(t.postedAt.date.short) · ").hType(.footnote).foregroundStyle(HColor.textSecondary)
        MoneyText(t.amount, figure: .compact, unit: .compact, hidden: app.amountsHidden, hiddenGlyphs: 3,
                  color: HColor.textSecondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    let name = category?.name ?? item.category.name
    let pill = HStack(spacing: 6) {
      Circle().fill((category?.hue ?? .other).dotGradient).frame(width: 8, height: 8)
      Text(name).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
      HIconView(.chevronDown, size: 12, color: HColor.iconSecondary)
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 36)
    .background(Capsule().fill(HColor.surfaceSecondary))
    return Button { app.fixCategory(t.id) } label: {
      Group {
        if typeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 8) {
            text
            pill
          }
        } else {
          HStack(spacing: 12) {
            MerchantMonogram(letter: String(t.merchant.prefix(1)).uppercased(), size: 32, ring: false)
            text
            pill
          }
        }
      }
      .frame(minHeight: 56)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(t.merchant), \(t.postedAt.date.short), \(app.amountsHidden ? "Amount hidden" : "\(t.amount.currency) \(MoneyFormat.string(t.amount.minor))"), \(name)")
    .accessibilityHint("Changes the category")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sortedForYou.fix.\(t.id)")
  }

  private func link(_ title: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.textLink)
        .frame(minHeight: HSpacing.targetMinimum)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
  }

  private func surface(_ radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
      .fill(HColor.widgetSurface)
      .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
      .shadow(color: .black.opacity(0.08), radius: 12, y: 8)
  }
}
