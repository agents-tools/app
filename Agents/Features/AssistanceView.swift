import SwiftUI

struct AssistanceView: View {
  @Bindable var model: AppModel
  var body: some View {
    if let session = model.assistanceSession {
      VStack(alignment: .leading, spacing: 16) {
        Text(session.input.action.rawValue).font(.headline)
        LabeledContent("Scope") { PathView(url: session.scope.root, scope: session.scope) }
        Text("Auxiliary on-device text. Review the facts before making configuration decisions.")
          .foregroundStyle(.secondary)
        switch session.stage {
        case .review:
          Text(
            "Only this selected content will be sent to the on-device model. Check that it contains no secrets."
          )
          ScrollView { Text(session.input.text).frame(maxWidth: .infinity, alignment: .leading) }
          if session.input.action == .translateDescription {
            TextField(
              "Target language",
              text: Binding(
                get: { model.assistanceSession?.input.language ?? "" },
                set: { model.assistanceSession?.input.language = $0 }))
          }
          if !session.input.withinLimit {
            Text("Select shorter content or a shorter language name.")
          }
        case .running: ProgressView("Generating on this Mac…")
        case .finished(let text):
          ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading) }
          Button("Copy Text") { copyText(text) }
        case .cancelled: Text("Cancelled. No changes were applied.")
        case .failed: Text("Assistance could not complete. No changes were applied.")
        case .outdated:
          Text("Selection or availability changed. Start again from the selected content.")
        }
        HStack {
          Button("Done") {
            model.cancelAssistance()
            model.assistanceSession = nil
          }
          .keyboardShortcut(.cancelAction)
          Spacer()
          if case .running = session.stage { Button("Cancel") { model.cancelAssistance() } }
          if case .review = session.stage {
            Button("Generate") { model.generateAssistance() }
              .disabled(!model.assistanceAvailable || !session.input.withinLimit)
          }
        }
      }.padding(24).frame(width: 560, height: 440).textSelection(.enabled)
    }
  }
}
