import AgentsCore
import SwiftUI

struct ComponentDraftEditor: View {
  @Binding var value: ComponentDraft
  let scope: InstallScope
  let defaultAgents: [AgentID]

  private var allowsAntigravity: Bool { value.kind.supportsAntigravity(in: scope) }

  var body: some View {
    Picker("Component", selection: Binding(get: { value.kind }, set: selectKind)) {
      ForEach(DeclaredComponentKind.allCases, id: \.self) {
        Text(DeclarationLabels.kind($0.rawValue)).tag($0)
      }
    }
    if value.kind != .skills && value.kind != .instructions { TextField("Name", text: $value.name) }
    switch value.kind {
    case .skills:
      TextField("Source alias", text: $value.source)
      SkillDraftEditor(value: $value.skills)
    case .instructions:
      InstructionDraftEditor(
        value: $value.instructions, scope: scope,
        defaultAgents: (value.agents ?? defaultAgents).filter {
          value.condition?.agents?.contains($0) ?? true
        })
      DisclosureGroup("Default Local Recipients") {
        AgentsEditor(
          value: $value.agents, title: "Specify defaults", allowsAntigravity: allowsAntigravity)
      }
    case .mcpServer: TransportEditor(value: $value.transport)
    case .hook:
      HookEventEditor(value: $value.event)
      ExecutableEditor(value: $value.run)
      OptionalText(title: "matcher", value: $value.matcher)
      Toggle(
        "Specify timeout",
        isOn: Binding(get: { value.timeout != nil }, set: { value.timeout = $0 ? 1 : nil }))
      if value.timeout != nil {
        TextField(
          "Timeout (seconds)",
          value: Binding(get: { value.timeout ?? 1 }, set: { value.timeout = $0 }), format: .number)
      }
    case .subagent:
      TextField("Description", text: $value.description)
      PromptBodyEditor(value: $value.prompt)
      OptionalText(title: "model", value: $value.model)
      OptionalLines(title: "tools", values: $value.tools)
    case .command:
      TextField("Description", text: $value.description)
      PromptBodyEditor(value: $value.prompt)
      DisclosureGroup("Parameters") {
        DraftRows(values: $value.parameters) { row, actions in
          TextField("Name", text: row.name)
          TextField("Description", text: row.description)
          OptionalText(title: "default value", value: row.defaultValue)
          DraftRowButtons(actions: actions)
        }
        Button("Add Parameter") { value.parameters.append(.init(name: "", description: "")) }
      }
    case .lspServer:
      ExecutableEditor(value: $value.run)
      DisclosureGroup("Languages") { StringDictionaryEditor(values: $value.languages) }
      DisclosureGroup("Initialization Options") { NativeDictionaryEditor(values: $value.options) }
    case .permissions: PermissionRulesEditor(values: $value.rules)
    case .ignore:
      LinesEditor(title: "Patterns", values: $value.patterns)
      Picker("Purpose", selection: $value.purpose) {
        Text("Context").tag(IgnorePurposeDeclaration.context)
        Text("Indexing").tag(IgnorePurposeDeclaration.indexing)
      }
    case .plugin:
      TextField("Source alias", text: $value.source)
      TextField("Path", text: $value.path)
      Picker("Mode", selection: $value.pluginMode) {
        Text("Native").tag(PluginModeDeclaration.native)
        Text("Components").tag(PluginModeDeclaration.components)
      }
      Toggle(
        "Specify component selection",
        isOn: Binding(
          get: { value.pluginSelection != nil }, set: { value.pluginSelection = $0 ? [] : nil }))
      if value.pluginSelection != nil {
        ForEach(DeclaredComponentKind.allCases, id: \.self) { kind in
          Toggle(
            DeclarationLabels.kind(kind.rawValue),
            isOn: Binding(
              get: { value.pluginSelection?.contains(kind) ?? false },
              set: {
                if $0 {
                  value.pluginSelection?.append(kind)
                } else {
                  value.pluginSelection?.removeAll { $0 == kind }
                }
              }))
        }
      }
      ComponentReferencesEditor(values: $value.pluginExclusions)
    }
    DisclosureGroup(value.kind == .instructions ? "Installation Conditions" : "Agents and Conditions") {
      if value.kind != .instructions {
        AgentsEditor(value: $value.agents, allowsAntigravity: allowsAntigravity)
      }
      ConditionEditor(value: $value.condition, allowsAntigravity: allowsAntigravity)
    }
    DisclosureGroup("Client Options") {
      NativeConfigurationEditor(
        values: $value.native,
        allowsAntigravity: allowsAntigravity && (value.kind == .mcpServer || value.kind == .hook))
    }
  }

  private func selectKind(_ kind: DeclaredComponentKind) {
    value.kind = kind
    if !kind.supportsAntigravity(in: scope) {
      value.agents?.removeAll { $0 == .antigravity }
      value.condition?.agents?.removeAll { $0 == .antigravity }
    }
  }
}

struct HookEventEditor: View {
  @Binding var value: HookEventDeclaration
  var body: some View {
    Picker(
      "Event",
      selection: Binding(
        get: { kind },
        set: {
          switch $0 {
          case "after": value = .afterTool
          case "start": value = .sessionStart
          case "end": value = .sessionEnd
          case "native": value = .native("")
          default: value = .beforeTool
          }
        })
    ) {
      Text("Before Tool").tag("before")
      Text("After Tool").tag("after")
      Text("Session Start").tag("start")
      Text("Session End").tag("end")
      Text("Native Event").tag("native")
    }
    if case .native(let event) = value {
      TextField("Native event", text: Binding(get: { event }, set: { value = .native($0) }))
    }
  }
  private var kind: String {
    switch value {
    case .beforeTool: "before"
    case .afterTool: "after"
    case .sessionStart: "start"
    case .sessionEnd: "end"
    case .native: "native"
    }
  }
}

struct PermissionRulesEditor: View {
  @Binding var values: [PermissionRuleDeclaration]
  var body: some View {
    DraftRows(values: $values) { row, actions in
      PermissionRuleEditor(value: row)
      DraftRowButtons(actions: actions)
    }
    Button("Add Rule") { values.append(.ask(.read, "")) }
  }
}

struct PermissionRuleEditor: View {
  @Binding var value: PermissionRuleDeclaration
  var body: some View {
    Picker("Effect", selection: Binding(get: { effect }, set: { update(effect: $0) })) {
      Text("Allow").tag("allow")
      Text("Ask").tag("ask")
      Text("Deny").tag("deny")
    }
    Picker(
      "Operation",
      selection: Binding(
        get: { operationKind },
        set: { kind in
          let operation: PermissionOperationDeclaration =
            kind == "write"
            ? .write : kind == "execute" ? .execute : kind == "tool" ? .tool("") : .read
          update(operation: operation)
        })
    ) {
      Text("Read").tag("read")
      Text("Write").tag("write")
      Text("Execute").tag("execute")
      Text("Tool").tag("tool")
    }
    if case .tool(let tool) = operation {
      TextField("Tool", text: Binding(get: { tool }, set: { update(operation: .tool($0)) }))
    }
    TextField("Pattern", text: Binding(get: { pattern }, set: { update(pattern: $0) }))
  }
  private var effect: String {
    switch value {
    case .allow: "allow"
    case .ask: "ask"
    case .deny: "deny"
    }
  }
  private var operation: PermissionOperationDeclaration {
    switch value {
    case .allow(let op, _), .ask(let op, _), .deny(let op, _): op
    }
  }
  private var pattern: String {
    switch value {
    case .allow(_, let p), .ask(_, let p), .deny(_, let p): p
    }
  }
  private var operationKind: String {
    switch operation {
    case .read: "read"
    case .write: "write"
    case .execute: "execute"
    case .tool: "tool"
    }
  }
  private func update(
    effect: String? = nil, operation: PermissionOperationDeclaration? = nil, pattern: String? = nil
  ) {
    let effect = effect ?? self.effect
    let op = operation ?? self.operation
    let pattern = pattern ?? self.pattern
    value =
      effect == "allow"
      ? .allow(op, pattern) : effect == "deny" ? .deny(op, pattern) : .ask(op, pattern)
  }
}

struct ComponentReferencesEditor: View {
  @Binding var values: [ComponentReferenceDeclaration]
  @State private var kind = "skill"
  @State private var name = ""
  var body: some View {
    DraftRows(values: $values) { row, actions in
      Text(referenceLabel(row.wrappedValue))
      DraftRowButtons(actions: actions)
    }
    Picker("Excluded kind", selection: $kind) {
      ForEach(
        [
          "skill", "instruction", "mcpServer", "hook", "subagent", "command", "lspServer",
          "permissions", "ignore", "plugin",
        ], id: \.self
      ) { Text(DeclarationLabels.kind($0)).tag($0) }
    }
    TextField("Excluded name", text: $name)
    Button("Add Exclusion") {
      let reference: ComponentReferenceDeclaration
      switch kind {
      case "instruction": reference = .instruction(name: name)
      case "mcpServer": reference = .mcpServer(name: name)
      case "hook": reference = .hook(name: name)
      case "subagent": reference = .subagent(name: name)
      case "command": reference = .command(name: name)
      case "lspServer": reference = .lspServer(name: name)
      case "permissions": reference = .permissions(name: name)
      case "ignore": reference = .ignore(name: name)
      case "plugin": reference = .plugin(name: name)
      default: reference = .skill(name: name)
      }
      values.append(reference)
      name = ""
    }.disabled(name.isEmpty)
  }
  private func referenceLabel(_ reference: ComponentReferenceDeclaration) -> String {
    switch reference {
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

}
