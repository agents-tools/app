import AgentsCore
import SwiftUI

struct DiscoveryView: View {
  @Bindable var model: AppModel
  var body: some View {
    if let session = model.discoverySession {
      VStack(alignment: .leading, spacing: 16) {
        Text("Review Declared Sources").font(.headline)
        Text(
          "Review the complete authored source selection without deploying it."
        )
        .foregroundStyle(.secondary)
        if session.isLoading { ProgressView("Resolving sources…") }
        if let discovery = session.discovery {
          List {
            ForEach(discovery.components, id: \.record) { component in
              DisclosureGroup(
                DeclarationLabels.kind(component.kind.rawValue) + " · " + component.name
              ) {
                LabeledContent("Source") { CompactText(text: component.source) }
                if let revision = component.revision {
                  LabeledContent("Revision") { CompactText(text: revision) }
                }
                LabeledContent(
                  "Agents", value: component.recipients.map(\.displayName).joined(separator: ", "))
                ForEach(component.resources, id: \.self) { Text($0) }
              }
            }
          }
          if discovery.components.isEmpty { Text("No components matched the current declaration.") }
          if session.stale { Text("Source inputs changed. Discover again before reviewing.") }
          Button("Inspect Again") { model.discoverComponents() }.disabled(!model.canModify)
          Button("Review Declared Update…") { model.previewDiscovery() }
            .disabled(session.stale || session.scope != model.scope || !model.canModify)
        }
        ForEach(session.messages) { Text($0.message) }
        Spacer()
        HStack {
          Spacer()
          Button("Done") { model.discoverySession = nil }.keyboardShortcut(.cancelAction)
        }
      }.padding(24).frame(width: 640, height: 540).textSelection(.enabled)
    }
  }
}
