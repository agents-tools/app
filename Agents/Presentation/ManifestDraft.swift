import AgentsCore
import AgentsManifest
import Foundation

struct ManifestDraft: Identifiable {
  enum Kind: String, CaseIterable, Identifiable {
    case defaults, source, component, group, reference, exports, structure
    var id: Self { self }
  }
  enum StructuralAction: String, CaseIterable { case move, remove }
  var isStale = false
  var insertBefore: NodeID?
  var destinationNode: NodeID?
  var originalName: String?
  var structuralAction: StructuralAction = .move
  var structuralNode: NodeID?
  var replacingNode: NodeID?
  var destinationGroup: NodeID? {
    didSet {
      if destinationGroup != oldValue {
        insertBefore = nil
        destinationNode = nil
      }
    }
  }
  var insertFirst = false
  let id = UUID()
  let scope: WorkspaceScope
  let document: DeclarationDocument?
  var kind: Kind = .component
  var defaultAgents: [AgentID]?
  var sourceAlias = ""
  var sourceKind: SourceKind = .local
  var sourceLocation = ""
  var sourcePath: String?
  var requirement: SourceRequirement?
  var component = ComponentDraft()
  var groupName = ""
  var groupComponents: [ComponentDeclaration] = []
  var groupUses: [GroupUseDeclaration] = []
  var groupCondition: DeclarationCondition?
  var referenceName = ""
  var referenceSource: String?
  var referenceCondition: DeclarationCondition?
  var exports: [String] = []

  func edits(home: URL) -> [ManifestEdit] {
    switch kind {
    case .defaults: return [.setDefaultAgents(defaultAgents)]
    case .source:
      let source = NamedSourceDeclaration(
        name: sourceAlias,
        source: .init(
          kind: sourceKind, location: sourceLocation, requirement: requirement, path: sourcePath,
          environment: .init(projectDirectory: scope.root, homeDirectory: home)))
      if let replacingNode { return [.replaceSource(replacingNode, with: source)] }
      return [.upsertSource(source)]
    case .component:
      if let replacingNode { return [.replaceComponent(replacingNode, with: component.value)] }
      return [
        .insertComponent(
          component.value, into: destinationGroup.map(ContainerID.group) ?? .root, at: .last)
      ]
    case .group:
      let removal: [ManifestEdit] =
        originalName.map { $0 != groupName ? [.removeGroup(name: $0)] : [] } ?? []
      return removal + [
        .upsertGroup(
          .init(
            name: groupName, components: groupComponents, uses: groupUses, condition: groupCondition
          ))
      ]
    case .reference:
      let removal: [ManifestEdit] = replacingNode.map { [.removeGroupReference($0)] } ?? []
      return removal + [
        .insertGroupReference(
          .init(
            name: referenceName, source: referenceSource,
            condition: referenceCondition),
          into: destinationGroup.map(ContainerID.group) ?? .root,
          at: insertBefore.map(InsertionPosition.before) ?? .last)
      ]
    case .exports: return [.setExports(exports)]
    case .structure:
      guard let node = structuralNode else { return [] }
      guard let item = structuralItems.first(where: { $0.id == node }) else { return [] }
      if structuralAction == .remove {
        switch item.category {
        case "Source": return [.removeSource(alias: item.title)]
        case "Group": return [.removeGroup(name: item.title)]
        case "Group Reference": return [.removeGroupReference(node)]
        case "Section": return [.removeSection(node)]
        default: return [.removeComponent(node)]
        }
      }
      let position: InsertionPosition =
        destinationNode.map {
          insertFirst ? .before($0) : .after($0)
        } ?? (insertFirst ? .first : .last)
      if item.category == "Section" { return [.moveSection(node, at: position)] }
      let container: ContainerID = destinationGroup.map(ContainerID.group) ?? .root
      if item.category == "Group Reference" {
        guard let reference = reference(at: item.pointer) else { return [] }
        return [
          .removeGroupReference(node),
          .insertGroupReference(reference, into: container, at: position),
        ]
      }
      return [.moveComponent(node, into: container, at: position)]
    }
  }

  var structuralItems: [DeclarationItem] {
    guard let document else { return [] }
    return CoreReader.items(document) + CoreReader.sectionItems(document)
  }

  func canReview(against snapshot: WorkspaceSnapshot?) -> Bool {
    guard let snapshot, snapshot.scope == scope else { return false }
    // Re-review can retain exact nodes only when Core's document digest is identical.
    return !isStale || snapshot.document?.digest == document?.digest
  }

  var structuralCanMove: Bool {
    guard let item = structuralItems.first(where: { $0.id == structuralNode }) else { return false }
    return ["Component", "Group Reference", "Section"].contains(item.category)
  }
  var structuralReady: Bool {
    structuralNode != nil && (structuralAction == .remove || structuralCanMove)
  }
  var positionItems: [DeclarationItem] {
    guard let selected = structuralItems.first(where: { $0.id == structuralNode }) else {
      return []
    }
    let parent: String
    if selected.category == "Section" {
      parent = "/" + selected.pointer.split(separator: "/").dropLast().joined(separator: "/")
    } else {
      let group = structuralItems.first { $0.id == destinationGroup }
      parent = (group?.pointer ?? "") + (selected.category == "Component" ? "/components" : "/uses")
    }
    return structuralItems.filter {
      $0.id != selected.id && $0.category == selected.category
        && "/" + $0.pointer.split(separator: "/").dropLast().joined(separator: "/") == parent
    }
  }

  func reference(at pointer: String) -> GroupUseDeclaration? { referenceValues[pointer] }

  var referenceValues: [String: GroupUseDeclaration] = [:]
}

struct ComponentDraft: Equatable {
  var kind: DeclaredComponentKind = .mcpServer
  var name = ""
  var source = ""
  var agents: [AgentID]?
  var condition: DeclarationCondition?
  var native: NativeConfiguration = [:]
  var skills = SkillDeclaration(select: .all)
  var instructions = InstructionsDeclaration()
  var registry: MCPRegistryEvidence?
  var transport = MCPTransportDeclaration.stdio(.init(executable: ""))
  var run = ExecutableDeclaration(executable: "")
  var event = HookEventDeclaration.beforeTool
  var matcher: String?
  var timeout: Int?
  var description = ""
  var prompt = PromptBody.literal("")
  var model: String?
  var tools: [String]?
  var parameters: [PromptParameterDeclaration] = []
  var languages: [String: String] = [:]
  var options: [String: NativeValue] = [:]
  var rules: [PermissionRuleDeclaration] = []
  var patterns: [String] = []
  var purpose = IgnorePurposeDeclaration.context
  var path = ""
  var pluginMode = PluginModeDeclaration.components
  var pluginSelection: [DeclaredComponentKind]?
  var pluginExclusions: [ComponentReferenceDeclaration] = []

  var value: ComponentDeclaration {
    switch kind {
    case .skills:
      var value = skills
      value.agents = agents
      value.condition = condition
      value.native = native
      return .skills(source: source, value)
    case .instructions:
      var value = instructions
      value.agents = agents
      value.condition = condition
      value.native = native
      return .instructions(value)
    case .mcpServer:
      return .mcpServer(
        name: name, transport: transport, agents: agents, condition: condition, native: native,
        registry: registry)
    case .hook:
      return .hook(
        name: name, event: event, run: run, matcher: matcher, timeoutSeconds: timeout,
        agents: agents, condition: condition, native: native)
    case .subagent:
      return .subagent(
        name: name, description: description, prompt: prompt, model: model, tools: tools,
        agents: agents, condition: condition, native: native)
    case .command:
      return .command(
        name: name, description: description, prompt: prompt, parameters: parameters,
        agents: agents, condition: condition, native: native)
    case .lspServer:
      return .lspServer(
        name: name, run: run, languages: languages, initializationOptions: options,
        agents: agents, condition: condition, native: native)
    case .permissions:
      return .permissions(
        name: name, rules: rules, agents: agents, condition: condition, native: native)
    case .ignore:
      return .ignore(
        name: name, patterns: patterns, purpose: purpose, agents: agents, condition: condition,
        native: native)
    case .plugin:
      return .plugin(
        name: name, path: path, source: source, mode: pluginMode, select: pluginSelection,
        exclude: pluginExclusions, agents: agents, condition: condition, native: native)
    }
  }
}
