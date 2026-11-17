import AgentsCore
import AgentsUpdates
import SwiftUI

struct ImportLocationView: View {
  let location: ImportLocationInspection
  var body: some View {
    LabeledContent("Document") { CompactText(text: location.document) }
    LabeledContent("Location") { CompactText(text: location.pointer) }
    if let span = location.span {
      LabeledContent("Line", value: String(span.line) + ":" + String(span.column))
    }
  }
}

struct ImportEffectsView: View {
  let effects: ImportSelectionEffects
  var body: some View {
    ForEach(Array(effects.sources.enumerated()), id: \.offset) { _, source in
      DetailsGroup("Source · " + source.alias) {
        if let declaration = source.declaration {
          CompactText(text: declaration.location)
        } else {
          Text("Exact source coordinates are required.")
        }
        if let revision = source.commit { LabeledContent("Commit") { CompactText(text: revision) } }
        if let version = source.version { LabeledContent("Version", value: version) }
        if let integrity = source.integrity {
          LabeledContent("Producer integrity") { CompactText(text: integrity) }
        }
        if let url = source.resolvedURL { CompactText(text: url) }
        if source.developmentOnly { Text("Development only") }
      }
    }
    ForEach(Array(effects.components.enumerated()), id: \.offset) { _, component in
      DetailsGroup(
        importedComponentTitle(component.declaration)
      ) {
        if case .skills(let source, let selection) = component.declaration {
          LabeledContent("Source", value: source)
          switch selection.select {
          case .all: Text("Selects all skills")
          case .names(let names): LabeledContent("Skills", value: names.joined(separator: ", "))
          }
          if let exclusions = selection.exclude {
            LabeledContent(
              "Exclusions", value: exclusions.isEmpty ? "None" : exclusions.joined(separator: ", "))
          }
        }
        if case .instructions(let instructions) = component.declaration {
          ForEach(Array(instructions.sectionReferences.enumerated()), id: \.offset) { _, section in
            LabeledContent("Section", value: section.reference)
          }
        }
        LabeledContent("Document", value: component.document)
        LabeledContent("Location") { CompactText(text: component.pointer) }
      }
    }
    ForEach(Array(effects.resources.enumerated()), id: \.offset) { _, resource in
      DetailsGroup("Resource · " + resource.producerName) {
        LabeledContent("Source", value: resource.sourceAlias)
        if let path = resource.path { CompactText(text: path) }
        if let hash = resource.hash {
          LabeledContent("Captured content") { CompactText(text: hash) }
        }
        if let integrity = resource.integrity {
          LabeledContent("Producer integrity") { CompactText(text: integrity) }
        }
        LabeledContent("Included", value: resource.selected ? "Yes" : "No")
        if resource.requiresStandaloneSource { Text("Requires independent authoring content.") }
        if resource.requiresBindingRewrite {
          Label(
            "Preserved content requires a binding rewrite", systemImage: "exclamationmark.triangle")
          Text(
            "Correct the explicit source or content, then inspect it again. Resolving a symbolic slot does not rewrite preserved files."
          )
          .foregroundStyle(.secondary)
        }
      }
    }
    ForEach(Array(effects.diagnostics.enumerated()), id: \.offset) { _, issue in
      VStack(alignment: .leading) {
        Text(issue.message)
        CompactText(text: issue.document + " · " + issue.pointer).font(.caption)
      }
    }
  }
}

struct ImportInputEditor: View {
  @Binding var value: ImportInputDraft
  var body: some View {
    Toggle("Supply this input", isOn: $value.enabled)
    if value.enabled {
      switch value.kind {
      case .sourceCoordinates:
        TextField("Git repository", text: $value.source.location)
        OptionalText(title: "search path", value: $value.source.path)
        RequirementEditor(value: $value.source.requirement)
      case .explicitContent:
        TextField("Authoring content path relative to input root", text: $value.path)
        Text("Choose independent authoring content, including any required support files.")
          .font(.caption).foregroundStyle(.secondary)
      case .bindingReference:
        Picker("Reference", selection: $value.reference) {
          Text("Environment variable").tag(ImportInputDraft.Reference.environment)
          Text("Secret reference").tag(ImportInputDraft.Reference.secret)
        }
        TextField(
          value.reference == .environment ? "Environment variable name" : "Secret reference name",
          text: $value.name)
        Text("Supply a symbolic reference name. Credential values are not import inputs.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

func importInputTitle(_ kind: ImportInputKind) -> String {
  switch kind {
  case .sourceCoordinates: "Source Coordinates"
  case .explicitContent: "Independent Content"
  case .bindingReference: "Symbolic Binding"
  }
}

func importedComponentTitle(_ declaration: ComponentDeclaration) -> String {
  switch declaration {
  case .skills(let source, _): "Skills · " + source
  case .instructions: "Instructions"
  default:
    DeclarationLabels.kind(declaration.kind.rawValue) + " · " + ComponentDraft(declaration).name
  }
}
