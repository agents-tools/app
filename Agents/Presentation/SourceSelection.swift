import AgentsCore
import AgentsUpdates
import Foundation

struct CatalogSession: Identifiable, Sendable {
  let id = UUID()
  let scope: WorkspaceScope
  var alias = ""
  var source = SourceDeclaration(kind: .local, location: "")
  var importing = false
  var format = ""
  var document = ""
  var catalog: SourceCatalogInspection?
  var selected: Set<SourceCatalogChoiceID> = []
  var inputs: [SourceCatalogInputID: ImportInputDraft] = [:]
  var strategy: PluginModeDeclaration?
  var agents: [AgentID]?
  var condition: DeclarationCondition?
  var skillMode: InstallMode?
  var busy = false
  var stale = false
  var messages: [AppDiagnostic] = []

  mutating func clearInspection() {
    catalog = nil
    selected = []
    inputs = [:]
    strategy = nil
  }

  mutating func capture(_ value: SourceCatalogInspection) {
    clearInspection()
    catalog = value
    inputs = Dictionary(
      uniqueKeysWithValues: value.requiredInputs.map {
        ($0.id, ImportInputDraft(kind: $0.kind, suggested: $0.suggestedReference))
      })
    stale = false
  }

  var selectionOptions: SourceCatalogSelectionOptions {
    .init(agents: agents, condition: condition, skillMode: skillMode)
  }
  var inputResolutions: [SourceCatalogInputResolution] {
    inputs.compactMap { id, draft in draft.value.map { .init(id: id, value: $0) } }
  }
}

/// Only the finite public input vocabulary is representable in these forms.
struct ImportInputDraft: Sendable {
  enum Reference: String, CaseIterable, Sendable { case environment, secret }
  let kind: ImportInputKind
  var enabled = false
  var source = SourceDeclaration(kind: .git, location: "")
  var path = ""
  var reference = Reference.environment
  var name = ""

  init(kind: ImportInputKind, suggested: ImportBindingReference? = nil) {
    self.kind = kind
    if let suggested {
      switch suggested {
      case .environment(let name): self.name = name
      case .secret(let name):
        reference = .secret
        self.name = name
      }
    }
  }

  var value: ImportInputValue? {
    guard enabled else { return nil }
    switch kind {
    case .sourceCoordinates: return .source(source)
    case .explicitContent: return .content(path: path)
    case .bindingReference:
      return .binding(reference == .environment ? .environment(name) : .secret(name))
    }
  }
}

extension ImportSession {
  var hasPendingResolution: Bool {
    selectedChoices != nil || inputs.values.contains(where: \.enabled)
  }
  var inputResolutions: [ImportInputResolution] {
    inputs.compactMap { id, draft in draft.value.map { .init(id: id, value: $0) } }
  }
  var rawResourcesBlocked: Bool {
    inspection?.resources.contains { $0.selected && $0.requiresBindingRewrite } == true
  }
  mutating func clearInspection() {
    inspection = nil
    selectedChoices = nil
    inputs = [:]
  }
  mutating func capture(_ value: SourceImportInspection) {
    inspection = value
    selectedChoices = nil
    inputs = Dictionary(
      uniqueKeysWithValues: value.requiredInputs.map {
        ($0.id, ImportInputDraft(kind: $0.kind, suggested: $0.suggestedReference))
      })
    stale = false
  }
}
