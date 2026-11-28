import AgentsCore
import AgentsUpdates
import Foundation

extension DeclaredComponentKind {
  private static let antigravityFormats = AgentClientOperations.schemaEvidence(for: .antigravity)
    .filter { $0.placement == .standalone && $0.status == .recorded }

  func supportsAntigravity(in scope: InstallScope) -> Bool {
    Self.antigravityFormats.contains { $0.kind == self && $0.scope == scope.rawValue }
  }
}

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

  mutating func setSource(_ value: SourceDeclaration) {
    source = value
    if value.kind == .wellKnown {
      if importing {
        agents = nil
        condition = nil
        skillMode = nil
      }
      importing = false
      format = ""
      document = ""
    }
    clearInspection()
  }

  mutating func clearInspection() {
    catalog = nil
    selected = []
    inputs = [:]
    strategy = nil
    removeUnavailableAntigravity()
  }

  var allowsAntigravity: Bool {
    guard !importing, !selected.isEmpty, let catalog else { return false }
    let choices = catalog.availableChoices.filter { selected.contains($0.id) }
    return choices.count == selected.count && choices.allSatisfy { choice in
      switch choice.unit {
      case .instruction:
        return DeclaredComponentKind.instructions.supportsAntigravity(in: scope.installScope)
      case .skill:
        return DeclaredComponentKind.skills.supportsAntigravity(in: scope.installScope)
      case .group, .componentsPlugin, .pluginMember:
        return !choice.effects.isEmpty && choice.effects.allSatisfy {
          $0.kind.supportsAntigravity(in: scope.installScope)
        }
      case .importer, .nativePlugin: return false
      }
    }
  }

  mutating func select(_ id: SourceCatalogChoiceID, included: Bool) {
    if included {
      selected.insert(id)
    } else {
      selected.remove(id)
    }
    removeUnavailableAntigravity()
  }

  private mutating func removeUnavailableAntigravity() {
    guard !allowsAntigravity else { return }
    agents?.removeAll { $0 == .antigravity }
    condition?.agents?.removeAll { $0 == .antigravity }
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
