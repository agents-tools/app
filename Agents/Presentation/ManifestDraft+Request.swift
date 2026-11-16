import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation

extension ManifestDraft {
  func updateRequest(home: URL) -> UpdateRequest {
    if let document {
      return UpdateRequest(
        operation: .edit(edits(home: home)), expectedDeclarationDigest: document.digest)
    }
    // The typed declaration owns omission/default semantics for a genuinely absent document.
    var declaration = Declaration()
    switch kind {
    case .defaults: declaration.agents = defaultAgents
    case .source:
      declaration.sourceDeclarations = [
        .init(
          name: sourceAlias,
          source: .init(
            kind: sourceKind, location: sourceLocation, requirement: requirement, path: sourcePath,
            environment: .init(projectDirectory: scope.root, homeDirectory: home)))
      ]
    case .component: declaration.components = [component.value]
    case .group:
      declaration.groups = [
        .init(
          name: groupName, components: groupComponents,
          uses: groupUses, condition: groupCondition)
      ]
    case .reference:
      declaration.uses = [
        .init(
          name: referenceName, source: referenceSource,
          condition: referenceCondition)
      ]
    case .exports: declaration.exports = exports
    case .structure: break
    }
    return UpdateRequest(operation: .declaration(declaration), expectedDeclarationDigest: "absent")
  }

  mutating func load(_ item: DeclarationItem, from declaration: Declaration) {
    switch item.category {
    case "Source":
      guard let source = declaration.sourceDeclarations.first(where: { $0.name == item.title })
      else { return }
      kind = .source
      sourceAlias = source.name
      sourceKind = source.source.kind
      sourceLocation = source.source.location
      sourcePath = source.source.path
      requirement = source.source.requirement
    case "Group":
      guard let group = declaration.groups.first(where: { $0.name == item.title }) else { return }
      kind = .group
      groupName = group.name
      groupComponents = group.components
      groupUses = group.uses
      groupCondition = group.condition
    case "Component":
      let parts = item.pointer.split(separator: "/")
      let values: [ComponentDeclaration]
      if parts.count == 2 {
        values = declaration.components
      } else if parts.count == 4, let index = Int(parts[1]),
        declaration.groups.indices.contains(index)
      {
        values = declaration.groups[index].components
      } else {
        return
      }
      guard let index = parts.last.flatMap({ Int($0) }), values.indices.contains(index) else {
        return
      }
      kind = .component
      replacingNode = item.id
      component = ComponentDraft(values[index])
    default: break
    }
  }
}
