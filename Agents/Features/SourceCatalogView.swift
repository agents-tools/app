import AgentsCore
import AgentsUpdates
import SwiftUI

struct SourceCatalogView: View {
  @Bindable var model: AppModel
  var body: some View {
    if let session = model.catalogSession {
      VStack(alignment: .leading, spacing: 12) {
        Text("Add from Source").font(.headline)
        PathView(url: session.scope.root, scope: session.scope)
        Form {
          Section("Source Coordinates") {
            if let sources = model.snapshot?.inspection.declaration?.sources, !sources.isEmpty {
              Menu("Use Declared Source") {
                ForEach(sources.keys.sorted(), id: \.self) { alias in
                  Button(alias) {
                    model.catalogSession?.alias = alias
                    model.catalogSession?.setSource(sources[alias]!)
                  }
                }
              }
            }
            TextField(
              "Alias",
              text: Binding(
                get: { session.alias },
                set: {
                  model.catalogSession?.alias = $0
                  model.catalogSession?.clearInspection()
                }))
            SourceDeclarationEditor(
              value: Binding(
                get: { session.source },
                set: {
                  model.catalogSession?.setSource($0)
                }))
            if session.source.kind != .wellKnown {
              Toggle(
                "Inspect an import document",
                isOn: Binding(
                  get: { session.importing },
                  set: {
                    model.catalogSession?.importing = $0
                    model.catalogSession?.agents = nil
                    model.catalogSession?.condition = nil
                    model.catalogSession?.skillMode = nil
                    model.catalogSession?.clearInspection()
                  }))
            }
            if session.importing {
              Picker(
                "Format",
                selection: Binding(
                  get: { session.format },
                  set: {
                    model.catalogSession?.format = $0
                    model.catalogSession?.clearInspection()
                  })
              ) {
                Text("Choose a format").tag("")
                ForEach(ImportFormatChoice.allCases) { Text($0.title).tag($0.rawValue) }
              }
              TextField(
                "Document relative to source root",
                text: Binding(
                  get: { session.document },
                  set: {
                    model.catalogSession?.document = $0
                    model.catalogSession?.clearInspection()
                  }))
            }
            Button(session.catalog == nil ? "Inspect Source" : "Inspect Again") {
              model.inspectCatalog()
            }
            .disabled(
              !model.canModify || session.alias.isEmpty || session.source.location.isEmpty
                || (session.importing && (session.format.isEmpty || session.document.isEmpty)))
          }
          if let catalog = session.catalog {
            Section("Available Content") {
              LabeledContent("Source") { CompactText(text: catalog.sourceIdentity) }
              LabeledContent("Revision") { CompactText(text: catalog.revision) }
              let strategies = catalog.availableChoices.compactMap { catalogStrategy($0.unit) }
              if !strategies.isEmpty {
                Picker(
                  "Plugin strategy",
                  selection: Binding(
                    get: { session.strategy },
                    set: { strategy in
                      model.catalogSession?.strategy = strategy
                      model.catalogSession?.agents = nil
                      let pluginIDs = Set(
                        catalog.availableChoices.filter { catalogStrategy($0.unit) != nil }.map(
                          \.id))
                      model.catalogSession?.selected.subtract(pluginIDs)
                    })
                ) {
                  Text("Choose a strategy").tag(Optional<PluginModeDeclaration>.none)
                  if strategies.contains(.native) {
                    Text("Native registration").tag(Optional(PluginModeDeclaration.native))
                  }
                  if strategies.contains(.components) {
                    Text("Components").tag(Optional(PluginModeDeclaration.components))
                  }
                }
              }
              ForEach(catalog.availableChoices, id: \.id) { choice in
                DetailsGroup(choice.label) {
                  LabeledContent("Selection unit", value: catalogUnitLabel(choice.unit))
                  ImportLocationView(location: choice.origin)
                  let strategyMatches =
                    catalogStrategy(choice.unit).map { $0 == session.strategy } ?? true
                  Toggle(
                    "Include this unit",
                    isOn: Binding(
                      get: { model.catalogSession?.selected.contains(choice.id) == true },
                      set: {
                        if $0 {
                          model.catalogSession?.selected.insert(choice.id)
                        } else {
                          model.catalogSession?.selected.remove(choice.id)
                        }
                      })
                  )
                  .disabled(choice.unavailableReason != nil || !strategyMatches)
                  if !strategyMatches {
                    Text("Choose this unit’s plugin strategy above to select it.").foregroundStyle(
                      .secondary)
                  }
                  if let reason = choice.unavailableReason {
                    Text(reason).foregroundStyle(.secondary)
                  }
                  if case .nativePlugin = choice.unit {
                    Text(
                      "Native registration is one indivisible unit with its captured single recipient."
                    )
                    .foregroundStyle(.secondary)
                  }
                  if case .pluginMember(let member) = choice.unit {
                    LabeledContent("Typed member", value: componentReferenceLabel(member))
                  }
                  ForEach(Array(choice.effects.enumerated()), id: \.offset) { _, effect in
                    CatalogEffectView(effect: effect)
                  }
                  if let effects = choice.importedEffects { ImportEffectsView(effects: effects) }
                  ForEach(Array(choice.constraints.enumerated()), id: \.offset) { _, constraint in
                    DetailsGroup("Source Constraint") {
                      CompactText(text: constraint.source)
                      LabeledContent("Root", value: constraint.root)
                      if let requirement = constraint.requirement {
                        Text(DeclarationLabels.requirement(requirement))
                      }
                      ForEach(Array(constraint.referenceChain.enumerated()), id: \.offset) {
                        _, span in
                        Text(
                          span.document.rawValue + ":" + String(span.line) + ":"
                            + String(span.column))
                      }
                    }
                  }
                  if let digest = choice.artifactDigest {
                    LabeledContent("Artifact") { CompactText(text: digest) }
                  }
                }
              }
              if catalog.availableChoices.isEmpty {
                Text("No representable choices were found in this source.")
              }
              if let fixed = catalog.fixedEffects {
                DetailsGroup("Fixed Contributions") { ImportEffectsView(effects: fixed) }
              }
              ForEach(catalog.requiredInputs, id: \.id) { input in
                DetailsGroup(importInputTitle(input.kind)) {
                  ImportLocationView(location: input.location)
                  ImportInputEditor(
                    value: Binding(
                      get: {
                        model.catalogSession?.inputs[input.id]
                          ?? .init(kind: input.kind, suggested: input.suggestedReference)
                      },
                      set: { model.catalogSession?.inputs[input.id] = $0 }))
                }
              }
              ForEach(Array(catalog.bindings.enumerated()), id: \.offset) { _, binding in
                Text(binding.reason)
                if !binding.canResolveCanonicalSlot {
                  Text("Correct the explicit source or content and inspect again.").foregroundStyle(
                    .secondary)
                }
              }
              ForEach(Array(catalog.producerSelections.enumerated()), id: \.offset) { _, claim in
                DetailsGroup("Producer Claim · " + claim.kind) {
                  ForEach(Array(claim.values.enumerated()), id: \.offset) { _, name in
                    CompactText(text: name)
                  }
                }
              }
            }
            if !session.importing {
              Section("Selection Options") {
                if session.strategy != .native {
                  AgentsEditor(
                    value: Binding(
                      get: { session.agents }, set: { model.catalogSession?.agents = $0 }))
                }
                ConditionEditor(
                  value: Binding(
                    get: { session.condition }, set: { model.catalogSession?.condition = $0 }))
                if catalog.availableChoices.contains(where: {
                  if case .skill = $0.unit { true } else { false }
                }) {
                  Toggle(
                    "Specify skill installation mode",
                    isOn: Binding(
                      get: { session.skillMode != nil },
                      set: { model.catalogSession?.skillMode = $0 ? .link : nil }))
                  if session.skillMode != nil {
                    Picker(
                      "Mode",
                      selection: Binding(
                        get: { session.skillMode ?? .link },
                        set: { model.catalogSession?.skillMode = $0 })
                    ) {
                      Text("Link").tag(InstallMode.link)
                      Text("Copy").tag(InstallMode.copy)
                      Text("Edit").tag(InstallMode.edit)
                    }
                  }
                }
              }
            }
          }
        }.formStyle(.grouped).disabled(session.busy)
        if session.busy { ProgressView("Waiting for source inspection and cleanup…") }
        if session.stale {
          Text("Source or destination inputs changed. Inspect again before selecting content.")
        }
        ForEach(session.messages) { Text($0.message) }
        HStack {
          Button(session.busy ? "Cancel Queued Work" : "Done") {
            if session.busy { model.cancelQueuedOperations() } else { model.catalogSession = nil }
          }.keyboardShortcut(.cancelAction)
          Spacer()
          Text("\(session.selected.count) selected").foregroundStyle(.secondary)
          Button("Review Selected Addition…") { model.previewCatalogSelection() }
            .disabled(
              session.catalog == nil || session.selected.isEmpty || session.busy || session.stale
                || session.scope != model.scope || !model.canModify)
        }
      }.padding(24).frame(width: 720, height: 680).interactiveDismissDisabled(session.busy)
    }
  }
}

private func catalogStrategy(_ unit: SourceCatalogUnit) -> PluginModeDeclaration? {
  switch unit {
  case .nativePlugin: .native
  case .componentsPlugin, .pluginMember: .components
  default: nil
  }
}

private func catalogUnitLabel(_ unit: SourceCatalogUnit) -> String {
  switch unit {
  case .skill: "Skill"
  case .instruction: "Ordered instruction section"
  case .group: "Symbolic exported group"
  case .nativePlugin: "Native plugin registration"
  case .componentsPlugin: "Complete plugin components"
  case .pluginMember: "Typed plugin member"
  case .importer: "Adapter producer entry (all affected families)"
  }
}

private func componentReferenceLabel(_ value: ComponentReferenceDeclaration) -> String {
  switch value {
  case .skill(let name): "Skill · " + name
  case .instruction(let name): "Instructions · " + name
  case .mcpServer(let name): "MCP Server · " + name
  case .hook(let name): "Hook · " + name
  case .subagent(let name): "Subagent · " + name
  case .command(let name): "Command · " + name
  case .lspServer(let name): "Language Server · " + name
  case .permissions(let name): "Permissions · " + name
  case .ignore(let name): "Ignore Patterns · " + name
  case .plugin(let name): "Plugin · " + name
  }
}

private struct CatalogEffectView: View {
  let effect: SourceCatalogEffect
  var body: some View {
    DetailsGroup(DeclarationLabels.kind(effect.kind.rawValue) + " · " + effect.name) {
      LabeledContent("Source") { CompactText(text: effect.source) }
      LabeledContent("Revision") { CompactText(text: effect.revision) }
      LabeledContent(
        "Recipients", value: effect.recipients.map(\.displayName).joined(separator: ", "))
      if effect.chatGPT { Text("Includes named prompt output") }
      ForEach(Array(effect.conditions.enumerated()), id: \.offset) { _, condition in
        CatalogConditionView(condition: condition)
      }
      ForEach(Array(effect.resources.enumerated()), id: \.offset) { _, path in
        LabeledContent("Resource", value: path)
      }
      ForEach(Array(effect.occurrences.enumerated()), id: \.offset) { _, occurrence in
        DetailsGroup("Provenance") {
          CompactText(text: occurrence.provenance.sourceIdentity)
          LabeledContent("Path", value: occurrence.provenance.relativePath)
          LabeledContent("Format", value: occurrence.provenance.format)
          if let group = occurrence.provenance.group { LabeledContent("Group", value: group) }
          if let pointer = occurrence.provenance.pointer { CompactText(text: pointer) }
          LabeledContent(
            "Recipients", value: occurrence.recipients.map(\.displayName).joined(separator: ", "))
          CatalogConditionView(condition: occurrence.condition)
          ForEach(Array(occurrence.dependencies.enumerated()), id: \.offset) { _, dependency in
            CompactText(text: dependency)
          }
          ForEach(Array(occurrence.provenance.referenceChain.enumerated()), id: \.offset) {
            _, span in
            Text(span.document.rawValue + ":" + String(span.line) + ":" + String(span.column))
          }
        }
      }
    }
  }
}

private struct CatalogConditionView: View {
  let condition: DeclarationCondition
  var body: some View {
    LabeledContent(
      "Agents",
      value: condition.agents.map {
        $0.isEmpty ? "None" : $0.map(\.displayName).joined(separator: ", ")
      } ?? "Any")
    LabeledContent(
      "Scopes",
      value: condition.scopes.map {
        $0.isEmpty ? "None" : $0.map { $0 == .user ? "User" : "Project" }.joined(separator: ", ")
      } ?? "Any")
    LabeledContent(
      "Platforms",
      value: condition.platforms.map {
        $0.isEmpty ? "None" : $0.map(\.rawValue).joined(separator: ", ")
      } ?? "Any")
  }
}
