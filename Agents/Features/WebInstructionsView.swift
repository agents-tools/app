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

  var body: some View {
    let destination = configuration.destination
    let saved = model.preferences.webInstructionSelections[configuration.preferenceKey] ?? []
    let selected = selection ?? saved
    let available = configuration.accepts(selected)
    Section(destination.title) {
      if saved.isEmpty {
        Text("Choose the instruction units to include.").foregroundStyle(.secondary)
      } else {
        LabeledContent("Instruction Units", value: saved.joined(separator: ", "))
      }
      if selection == nil && !available {
        Text("Some saved instruction units are unavailable. Update the selection to preview it.")
          .foregroundStyle(.secondary)
      }
      HStack {
        Button(selection == nil ? "Configure…" : "Cancel") {
          selection = selection == nil ? saved : nil
        }
        .disabled(model.isTerminating)
        .accessibilityIdentifier("instructions.web.configure." + destination.id)
        Button("Preview Selection…") {
          model.previewWebInstructionSelection(selected, in: configuration)
        }
        .disabled(selected.isEmpty || !available || model.isApplying || model.isTerminating)
        .accessibilityIdentifier("instructions.web.preview." + destination.id)
      }
      .buttonStyle(.borderless)
      if selection != nil {
        if configuration.choices.isEmpty {
          Text("Add instruction units in this scope before configuring this destination.")
            .foregroundStyle(.secondary)
        }
        ForEach(configuration.choices, id: \.self) { reference in
          Toggle(isOn: selectionBinding(reference)) { Text(verbatim: reference) }
        }
        let unavailable = selected.filter { !configuration.choices.contains($0) }
        ForEach(unavailable, id: \.self) { reference in
          Toggle(isOn: selectionBinding(reference)) {
            Text("\(reference) (unavailable)")
          }
        }
        Button("Save Selection in App") {
          model.saveWebInstructionSelection(selected, in: configuration)
          selection = nil
        }
        .disabled(!available || selected == saved || model.isTerminating)
        .accessibilityIdentifier("instructions.web.save." + destination.id)
      }
      if configuration.hasNamedPrompt {
        Button("Preview Named Prompt…") {
          model.previewPrompt(name: destination.rawValue, in: configuration.scope)
        }
        .disabled(model.isApplying || model.isTerminating)
        .accessibilityIdentifier("instructions.web.named." + destination.id)
      }
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
