import HasalaDesign
import HasalaModels
import SwiftUI

/// A small tinted tag ("To review", "Refund").
struct InfoTag: View {
  let text: String
  let tone: StatusTone

  init(_ text: String, tone: StatusTone) {
    self.text = text
    self.tone = tone
  }

  var body: some View {
    Text(text).hType(.footnote.weight(.semibold)).foregroundStyle(tone.foreground)
      .padding(.horizontal, 10).padding(.vertical, 4)
      .background(tone.surface, in: Capsule())
  }
}
