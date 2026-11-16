import SwiftUI

struct PromptPreviewView: View {
  @Bindable var model: AppModel

  var body: some View {
    if let session = model.promptSession {
      VStack(alignment: .leading, spacing: 16) {
        Text(session.name).font(.headline)
        Text(session.scope.title).foregroundStyle(.secondary)
        switch session.stage {
        case .loading:
          HStack {
            ProgressView().controlSize(.small)
            Text("Generating prompt preview…")
          }
        case .ready(let text):
          ScrollView {
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
          }
          Button("Copy Prompt") { copyText(text) }
        case .failed:
          ForEach(session.messages) { Text($0.message).textSelection(.enabled) }
        case .outdated:
          Text("The selection changed. Generate a new preview for the current selection.")
        case .cancelled:
          Text("The preview was cancelled before it started.")
        }
        HStack {
          Spacer()
          Button("Done") { model.promptSession = nil }.keyboardShortcut(.defaultAction)
        }
      }
      .padding(24)
      .frame(minWidth: 520, idealWidth: 640, minHeight: 280, idealHeight: 500)
    }
  }
}
