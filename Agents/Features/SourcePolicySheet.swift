import AgentsCore
import AgentsUpdates
import SwiftUI

struct SourcePolicySheet: View {
  let scope: WorkspaceScope
  let environment: RuntimeEnvironment
  let didSave: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var editor: SourcePolicyEditor?
  @State private var original = ""
  @State private var draft = ""
  @State private var layers: [SourcePolicyLayer] = []
  @State private var failure: String?
  @State private var busy = true

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Source Policy").font(.headline)
      if let editor {
        Text(editor.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        ConfigurationYAMLEditor(label: "Source policy YAML", text: $draft)
        ForEach(layers.filter { $0.scope.rawValue != scope.installScope.rawValue }, id: \.url) {
          layer in
          DisclosureGroup(layer.scope == .organization ? "Organization Policy" : "User Policy") {
            VStack(alignment: .leading) {
              Text(layer.url.path).font(.caption).textSelection(.enabled)
              if let allow = layer.rules.allow {
                Text(
                  allow.isEmpty
                    ? "No sources allowed"
                    : "Allow: " + allow.map(\.description).joined(separator: ", "))
              }
              if !layer.rules.deny.isEmpty {
                Text("Deny: " + layer.rules.deny.map(\.description).joined(separator: ", "))
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
      Spacer(minLength: 0)
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction).disabled(editor == nil || busy || draft == original)
      }
    }.padding(20).frame(minWidth: 560, minHeight: 430)
      .interactiveDismissDisabled(busy)
      .task {
        defer { busy = false }
        do {
          let editing = try SourcePolicyEditor(scope: scope.installScope, environment: environment)
          if let bytes = editing.original {
            guard let text = String(data: bytes, encoding: .utf8) else {
              throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            original = text
          } else {
            original = "version: 1\n"
          }
          draft = original
          editor = editing
          layers = try SourcePolicyOperations.inspect(
            scope: scope.installScope, environment: environment
          ).effective.layers
        } catch {
          failure = String(describing: error)
        }
      }
  }

  private func save() {
    guard let editor else { return }
    busy = true
    failure = nil
    let bytes = Data(draft.utf8)
    Task {
      defer { busy = false }
      do {
        try await Task.detached(priority: .userInitiated) { try editor.save(bytes) }.value
        didSave()
        dismiss()
      } catch {
        failure = String(describing: error)
      }
    }
  }
}
