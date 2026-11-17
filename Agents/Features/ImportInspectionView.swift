import AgentsUpdates
import SwiftUI

struct ImportInspectionView: View {
  @Bindable var model: AppModel
  let inspection: SourceImportInspection
  var body: some View {
    if let session = model.importSession {
      Section("Captured Import") {
        LabeledContent("Format", value: inspection.format)
        Text(inspection.specificationStatus).foregroundStyle(.secondary)
        if let revision = inspection.producerRevision {
          LabeledContent("Producer revision") { CompactText(text: revision) }
        }
        Toggle(
          "Choose specific producer entries",
          isOn: Binding(
            get: { model.importSession?.selectedChoices != nil },
            set: { model.importSession?.selectedChoices = $0 ? [] : nil }))
        Text(
          session.selectedChoices == nil
            ? "Keep the current producer selection. Inspect again to restore the adapter’s default selection."
            : "An empty choice list uses this adapter’s explicit empty-selection behavior. Fixed contributions remain visible below."
        )
        .font(.caption).foregroundStyle(.secondary)
        ForEach(inspection.availableChoices, id: \.id) { choice in
          DetailsGroup(choice.label) {
            if session.selectedChoices != nil {
              Toggle(
                "Include this producer entry",
                isOn: Binding(
                  get: { model.importSession?.selectedChoices?.contains(choice.id) == true },
                  set: {
                    if $0 {
                      model.importSession?.selectedChoices?.insert(choice.id)
                    } else {
                      model.importSession?.selectedChoices?.remove(choice.id)
                    }
                  }))
            }
            ForEach(Array(choice.locations.enumerated()), id: \.offset) { _, location in
              ImportLocationView(location: location)
            }
            ImportEffectsView(effects: choice.effects)
          }
        }
        if inspection.availableChoices.isEmpty {
          Text("This adapter issued no selectable entries.")
        }
        DetailsGroup("Fixed Contributions") { ImportEffectsView(effects: inspection.fixedEffects) }
      }
      Section("Supported Inputs") {
        ForEach(inspection.requiredInputs, id: \.id) { input in
          DetailsGroup(importInputTitle(input.kind)) {
            ImportLocationView(location: input.location)
            ImportInputEditor(
              value: Binding(
                get: {
                  model.importSession?.inputs[input.id]
                    ?? .init(kind: input.kind, suggested: input.suggestedReference)
                },
                set: { model.importSession?.inputs[input.id] = $0 }))
          }
        }
        ForEach(Array(inspection.bindings.enumerated()), id: \.offset) { _, binding in
          Text(binding.reason)
          CompactText(text: binding.document + " · " + binding.pointer).font(.caption)
          if !binding.canResolveCanonicalSlot {
            Text(
              "Correct the source or authoring content and inspect again; this requirement has no supported symbolic input."
            )
            .foregroundStyle(.secondary)
          }
        }
        Button("Resolve Selection and Inputs") { model.resolveImportSelection() }
          .disabled(
            session.stale || session.scope != model.scope || !session.hasPendingResolution
              || !model.canModify)
      }
      Section("Current Conversion") {
        ForEach(Array(inspection.sources.enumerated()), id: \.offset) { _, source in
          DetailsGroup("Source · " + source.alias) {
            if let version = source.version { LabeledContent("Version", value: version) }
            if let commit = source.commit {
              LabeledContent("Commit") { CompactText(text: commit) }
            }
            if let integrity = source.integrity {
              LabeledContent("Producer integrity") { CompactText(text: integrity) }
            }
            if let url = source.resolvedURL {
              LabeledContent("Resolved source") { CompactText(text: url) }
            }
          }
        }
        ForEach(Array(inspection.components.enumerated()), id: \.offset) { _, component in
          Text(
            importedComponentTitle(component.declaration))
        }
        ForEach(Array(inspection.resources.enumerated()), id: \.offset) { _, resource in
          LabeledContent("Resource", value: resource.producerName)
          if let hash = resource.hash {
            LabeledContent("Captured content") { CompactText(text: hash) }
          }
          if let integrity = resource.integrity {
            LabeledContent("Producer integrity") { CompactText(text: integrity) }
          }
          if resource.requiresBindingRewrite {
            Text("Preserved content requires a binding rewrite before import.")
            Text(
              "Correct the explicit authoring content and inspect again. Symbolic inputs do not rewrite raw files."
            )
            .foregroundStyle(.secondary)
          }
          if resource.requiresStandaloneSource { Text("Requires independent authoring content.") }
        }
        ForEach(Array(inspection.diagnostics.enumerated()), id: \.offset) { _, issue in
          Text(issue.message)
          CompactText(text: issue.document + " · " + issue.pointer).font(.caption)
        }
        ForEach(Array(inspection.selections.enumerated()), id: \.offset) { _, claim in
          DetailsGroup("Producer Claim · " + claim.kind) {
            if let source = claim.sourceAlias { Text(source) }
            ForEach(Array(claim.values.enumerated()), id: \.offset) { _, value in
              CompactText(text: value)
            }
            Text(claim.automatic ? "Automatic selection" : "Explicit selection")
            if claim.developmentOnly { Text("Development only") }
          }
        }
        ForEach(Array(inspection.orderedSources.enumerated()), id: \.offset) { _, source in
          DetailsGroup("Ordered Source · " + source.alias) {
            CompactText(text: source.identity)
            LabeledContent("Transport", value: source.transport)
            LabeledContent("Skills path", value: source.skillsPath)
            LabeledContent("Rules path", value: source.rulesPath)
            if let skills = source.skills {
              LabeledContent("Skills", value: skills.joined(separator: ", "))
            }
            if let rules = source.rules {
              LabeledContent("Rules", value: rules.joined(separator: ", "))
            }
          }
        }
        if !inspection.deployments.isEmpty {
          Text("Producer deployment claims do not grant ownership of installed content.")
        }
        if session.stale { Text("Inputs changed. Inspect again before continuing.") }
        if session.hasPendingResolution {
          Text("Resolve the selected choices and inputs before reviewing their changes.")
        }
        Button("Review Changes…") { model.reviewImport() }
          .disabled(
            session.stale || session.scope != model.scope || session.hasPendingResolution
              || session.rawResourcesBlocked
              || !model.canModify)
      }
    }
  }
}
