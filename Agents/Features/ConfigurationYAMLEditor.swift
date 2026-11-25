import SwiftUI

struct ConfigurationYAMLEditor: View {
  let label: LocalizedStringKey
  @Binding var text: String

  var body: some View {
    TextEditor(text: $text)
      .font(.body.monospaced())
      .accessibilityLabel(label)
  }
}
