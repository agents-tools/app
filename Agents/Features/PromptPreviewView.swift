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
            Text(
              session.copyAfterRead == nil
                ? "Generating prompt preview…" : "Reading managed instructions…")
          }
        case .ready(let text):
          ScrollView {
            Text(verbatim: text).textSelection(.enabled).frame(
              maxWidth: .infinity, alignment: .leading)
          }
          HStack {
            Button("Copy Text") {
              model.copyInstructionPreview(copy: copyText)
            }
            if let copied = session.clipboardResult {
              Text(copied ? "Copied to Clipboard" : "Couldn’t write to the clipboard.")
                .foregroundStyle(.secondary)
            }
          }
        case .failed:
          ForEach(session.messages) { Text($0.message).textSelection(.enabled) }
        case .outdated:
          Text("The selection changed. Try again for the current selection.")
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
