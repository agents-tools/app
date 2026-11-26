import AgentsCore
import AgentsUpdates

enum WebInstructionDestination: String, CaseIterable, Identifiable {
  case chatGPT = "chatgpt-web"
  case gemini = "gemini-web"

  var id: String { rawValue }
  var title: String { self == .chatGPT ? "ChatGPT Web" : "Gemini Web" }
}

struct WebInstructionConfiguration {
  let destination: WebInstructionDestination
  let scope: WorkspaceScope
  let choices: [String]
  let hasNamedPrompt: Bool

  var preferenceKey: String { destination.id + ":" + scope.id }

  init(
    _ destination: WebInstructionDestination, snapshot: WorkspaceSnapshot,
    environment: RuntimeEnvironment
  ) {
    self.destination = destination
    scope = snapshot.scope
    let declaration = snapshot.inspection.declaration ?? Declaration()
    let installScope = snapshot.scope.installScope
    let authored = Self.activeInstructions(declaration, scope: installScope)
    var references = Set((snapshot.ownInstructions ?? []).map(\.id.name))
    for instructions in authored {
      references.formUnion(
        instructions.sectionReferences.filter {
          Self.matches($0.condition, installScope)
        }.map(\.reference))
      for named in instructions.prompts where Self.matches(named.prompt.condition, installScope) {
        references.formUnion(
          named.prompt.sectionReferences.filter {
            Self.matches($0.condition, installScope)
          }.map(\.reference))
      }
    }
    let resolved = snapshot.inspection.components.filter {
      $0.kind == .instructions && ($0.chatGPT || !$0.recipients.isEmpty)
    }
    let resources = Dictionary(
      uniqueKeysWithValues: snapshot.inspection.resources.map {
        ($0.identity, $0.path)
      })
    for entry in declaration.sourceDeclarations {
      guard let identity = try? entry.source.identity(environment: environment) else { continue }
      let root = entry.source.path.flatMap { $0 == "." ? nil : $0 + "/" } ?? ""
      references.formUnion(
        resolved.compactMap { component -> String? in
          guard component.source == identity,
            let path = component.resources.first.flatMap({ resources[$0] })
          else { return nil }
          let suffix = "/instructions/" + component.name + ".md"
          guard
            path == root + "instructions/" + component.name + ".md"
              || path == root + ".agents" + suffix
          else { return nil }
          return SectionDeclaration(name: component.name, source: entry.name).reference
        })
    }
    choices = references.sorted()
    hasNamedPrompt =
      snapshot.mappings.first { $0.scope == snapshot.scope }?
      .prompts[destination.rawValue] != nil
  }

  func accepts(_ selection: [String]) -> Bool {
    let selected = Set(selection)
    return selected.count == selection.count && selected.isSubset(of: Set(choices))
  }

  private static func activeInstructions(
    _ declaration: Declaration, scope: InstallScope
  ) -> [InstructionsDeclaration] {
    var components = declaration.components
    var pending = declaration.uses
    var visited = Set<String>()
    while let use = pending.popLast() {
      guard use.source == nil || use.source == ".", matches(use.condition, scope),
        let group = declaration.groups.first(where: { $0.name == use.name }),
        matches(group.condition, scope), visited.insert(group.name).inserted
      else { continue }
      components += group.components
      pending += group.uses
    }
    return components.compactMap {
      guard case .instructions(let instructions) = $0, matches(instructions.condition, scope)
      else { return nil }
      return instructions
    }
  }

  private static func matches(_ condition: DeclarationCondition?, _ scope: InstallScope) -> Bool {
    (condition?.scopes?.contains(scope) ?? true)
      && (condition?.platforms?.contains(.macOS) ?? true)
  }
}

extension AppModel {
  func saveWebInstructionSelection(
    _ selection: [String], in configuration: WebInstructionConfiguration
  ) {
    guard !isTerminating, scope == configuration.scope, configuration.accepts(selection)
    else { return }
    let key = configuration.preferenceKey
    preferences.webInstructionSelections[key] = selection.isEmpty ? nil : selection
  }
}
