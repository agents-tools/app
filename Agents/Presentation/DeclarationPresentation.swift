import AgentsCore

struct AuthoredFields: Sendable {
  let sourceMap: DeclarationSourceMap

  func contains(_ pointer: String) -> Bool {
    sourceMap.locations(at: pointer).contains { !$0.defaulted }
  }

  static func child(_ name: String, of pointer: String) -> String {
    pointer + "/"
      + name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
  }
}

enum DeclarationLabels {
  static func kind(_ kind: String) -> String {
    switch kind {
    case "mcpServer": "MCP Server"
    case "lspServer": "Language Server"
    case "skills": "Skills"
    case "instructions": "Instructions"
    case "hook": "Hook"
    case "subagent": "Subagent"
    case "command": "Command"
    case "permissions": "Permissions"
    case "ignore": "Ignore Patterns"
    case "plugin": "Plugin"
    case "git": "Git Repository"
    case "local": "Local Directory"
    case "well-known", "wellKnown": "Skill Index"
    case "stdio": "Local Process"
    case "streamableHTTP": "Streamable HTTP"
    case "sse": "Server-Sent Events"
    case "group": "Group"
    case "exported": "Source Group"
    case "promptDeclaration": "Named Prompt"
    case "literal": "Text"
    case "decimal": "Decimal"
    case "null": "Null"
    default: kind.prefix(1).uppercased() + kind.dropFirst()
    }
  }

  static func requirement(_ value: SourceRequirement) -> String {
    switch value {
    case .branch(let name): "Branch: " + name
    case .revision(let revision): "Commit: " + revision
    case .exact(let version): "Version: " + version
    case .upToNextMajor(let version): "From " + version + " to the next major version"
    case .upToNextMinor(let version): "From " + version + " to the next minor version"
    case .range(let from, let to): "From " + from + " to " + to
    }
  }

  static func field(_ field: String) -> String {
    switch field {
    case "agents": "Agents"
    case "condition": "Conditions"
    case "native": "Client Options"
    case "workingDirectory": "Working Directory"
    case "chatGPT": "Named Prompts"
    case "source": "Source"
    case "select": "Selection"
    case "subpath": "Search Path"
    case "initializationOptions": "Initialization Options"
    case "defaultValue": "Default Value"
    case "timeoutSeconds": "Timeout (seconds)"
    case "url": "URL"
    default: field.prefix(1).uppercased() + field.dropFirst()
    }
  }
}

extension MappingItem {
  var copyText: String {
    var lines = [title, "Location: " + scope.root.path, status]
    for target in targets {
      lines += ["", "Target: " + target.id, "Agents: " + target.agents]
      if let imported = target.importedFile { lines.append("Imports: " + imported) }
      lines += target.sections.map { "Section: " + $0 }
    }
    if !unplaced.isEmpty { lines += ["", "Unplaced Sections:"] + unplaced }
    for name in prompts.keys.sorted() {
      lines += ["", "Prompt: " + name] + (prompts[name] ?? []).map { "Section: " + $0 }
    }
    return lines.joined(separator: "\n")
  }
}
