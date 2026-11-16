import AgentsCore
import AgentsManifest
import Foundation

struct ManifestDraft: Identifiable {
  enum Kind: String, CaseIterable, Identifiable {
    case defaults, source, component, group, reference, exports, structure
    var id: Self { self }
  }
  enum StructuralAction: String, CaseIterable { case move, remove }
  var structuralAction: StructuralAction = .move
  var structuralNode: NodeID?
  var replacingNode: NodeID?
  var destinationGroup: NodeID?
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
      return [
        .upsertSource(
          .init(
            name: sourceAlias,
            source: .init(
              kind: sourceKind, location: sourceLocation, requirement: requirement,
              path: sourcePath,
              environment: .init(projectDirectory: scope.root, homeDirectory: home))))
      ]
    case .component:
      if let replacingNode { return [.replaceComponent(replacingNode, with: component.value)] }
      return [.insertComponent(component.value, into: .root, at: .last)]
    case .group:
      return [
        .upsertGroup(
          .init(
            name: groupName, components: groupComponents, uses: groupUses, condition: groupCondition
          ))
      ]
    case .reference:
      return [
        .insertGroupReference(
          .init(
            name: referenceName, source: referenceSource,
            condition: referenceCondition), into: .root, at: .last)
      ]
    case .exports: return [.setExports(exports)]
    case .structure:
      guard let node = structuralNode else { return [] }
      if structuralAction == .remove { return [.removeComponent(node)] }
      let container: ContainerID = destinationGroup.map(ContainerID.group) ?? .root
      return [.moveComponent(node, into: container, at: insertFirst ? .first : .last)]
    }
  }
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
        name: name, transport: transport, agents: agents, condition: condition, native: native)
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
