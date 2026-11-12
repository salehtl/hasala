import HasalaDesign
import HasalaModels
import SwiftUI

struct ManageBanksSheet: View {
  let current: [SupportedBank]
  var onSaved: () -> Void

  @State private var chosen: Set<SupportedBank>
  @State private var busy = false
  @State private var failure: SetupFailure?
  @Environment(AccountSession.self) private var session: AccountSession?
  @Environment(\.dismiss) private var dismiss

  init(current: [SupportedBank], onSaved: @escaping () -> Void) {
    self.current = current
    self.onSaved = onSaved
    _chosen = State(initialValue: Set(current))
  }

  private var ordered: [SupportedBank] { SupportedBank.allCases.filter { chosen.contains($0) } }
  private var changed: Bool { chosen != Set(current) }
  private var removed: [SupportedBank] { current.filter { !chosen.contains($0) } }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Hasala reads only transaction alerts from the banks you pick.")
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
          BankList(chosen: chosen) { bank in
            if chosen.contains(bank) { chosen.remove(bank) } else { chosen.insert(bank) }
          }
          LockNote(text: note)
            .padding(.horizontal, 4)
          if let message = failure?.message {
            FailureBanner(failure: .badPhrase(message))
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 8)
        .padding(.bottom, 32)
      }
      .background(HColor.surfaceSecondary)
      .navigationTitle("Your banks")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .accessibilityIdentifier("banks.cancel")
        }
        ToolbarItem(placement: .confirmationAction) {
          if busy {
            ProgressView()
          } else {
            Button("Save") { Task { await save() } }
              .disabled(!changed || chosen.isEmpty || session == nil)
              .accessibilityIdentifier("banks.save")
          }
        }
      }
    }
    .interactiveDismissDisabled(busy)
  }

  private var note: String {
    if chosen.isEmpty { return "Pick at least one bank." }
    if !removed.isEmpty {
      return "Alerts from \(MailCopy.banks(removed)) stop. Past transactions stay."
    }
    return "Alerts are downloaded straight to this iPhone."
  }

  private func save() async {
    guard let setup = session?.services.setup, !chosen.isEmpty, !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await setup.setBanks(ordered)
      failure = nil
      onSaved()
      dismiss()
    } catch {
      failure = error
    }
  }
}
