import SwiftUI

struct WebInstructionsView: View {
  @Bindable var model: AppModel
  let snapshot: WorkspaceSnapshot

  var body: some View {
    ForEach(WebInstructionDestination.allCases) { destination in
      WebInstructionDestinationView(
        model: model,
        configuration: WebInstructionConfiguration(
          destination, snapshot: snapshot,
          environment: model.actions.environment(for: snapshot.scope)))
    }
  }
}

private struct WebInstructionDestinationView: View {
  @Bindable var model: AppModel
  let configuration: WebInstructionConfiguration

  @State private var selection: [String]?
  @State private var editingDigest: String?

  var body: some View {
    let destination = configuration.destination
    Section(destination.title) {
      if !configuration.canConfigure {
        Text("This prompt is supplied by another declaration or has multiple definitions.")
          .foregroundStyle(.secondary)
      } else if configuration.selected.isEmpty {
        Text("Choose the instruction units to include.").foregroundStyle(.secondary)
      } else {
        LabeledContent("Instruction Units", value: configuration.selected.joined(separator: ", "))
      }
      HStack {
        Button(selection == nil ? "Configure…" : "Cancel") {
          if selection == nil {
            selection = configuration.selected
            editingDigest = configuration.documentDigest
          } else {
            selection = nil
          }
        }
        .disabled(selection == nil && (!model.canModify || !configuration.canConfigure))
        .accessibilityIdentifier("instructions.web.configure." + destination.id)
        Button("Preview…") {
          model.previewPrompt(
            name: destination.rawValue, in: configuration.scope, title: destination.title)
        }
        .disabled(!configuration.hasPreview || model.isApplying || model.isTerminating)
        .accessibilityIdentifier("instructions.web.preview." + destination.id)
      }
      .buttonStyle(.borderless)
      if let selection {
        if editingDigest != configuration.documentDigest
          || !Set(selection).isSubset(of: Set(configuration.choices))
        {
          Text("The configuration changed. Reopen Configure to use the current instruction units.")
            .foregroundStyle(.secondary)
        } else if configuration.choices.isEmpty {
          Text("Add instruction units in this scope before configuring this destination.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(configuration.choices, id: \.self) { reference in
            Toggle(isOn: selectionBinding(reference)) { Text(verbatim: reference) }
          }
          Button("Review Selection…") {
            guard model.scope == configuration.scope,
              let request = configuration.updateRequest(selecting: selection)
            else { return }
            model.previewUpdate(title: "Configure " + destination.title, request: request)
          }
          .disabled(!model.canModify || selection == configuration.selected)
          .accessibilityIdentifier("instructions.web.review." + destination.id)
        }
      }
    }
    .onChange(of: configuration.selected) { _, applied in
      if applied == selection { selection = nil }
    }
  }

  private func selectionBinding(_ reference: String) -> Binding<Bool> {
    Binding(
      get: { selection?.contains(reference) == true },
      set: { included in
        if included {
          selection?.append(reference)
        } else {
          selection?.removeAll { $0 == reference }
        }
      })
  }
}
