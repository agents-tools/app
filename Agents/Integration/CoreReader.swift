import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Foundation

struct CoreReader: Sendable {
  let home: URL
  let processEnvironment: [String: String]

  func read(scope: WorkspaceScope) -> CoreCompletion {
    let runtime = RuntimeEnvironment(
      projectDirectory: scope.root, homeDirectory: home,
      environment: processEnvironment)
    let store = StateStore(scope: scope.installScope, environment: runtime)
    do {
      try ProjectRootAccess.requireAvailable(scope)
      let document = try store.loadManifest()
      var diagnostics =
        document?.diagnostics.map {
          AppDiagnostic(
            scope: scope, operation: "Manifest",
            severity: $0.severity == .error ? .error : .warning,
            message: "\($0.code): \($0.message) (line \($0.span.line), column \($0.span.column))",
            path: store.declarationURL.path)
        } ?? []
      // Each public read is independently coordinated; this is not an atomic cross-domain snapshot.
      func optionalRead<T>(_ name: String, _ body: () throws -> T) -> T? {
        do { return try body() } catch {
          diagnostics += Self.diagnostics(error, scope: scope, operation: name)
          return nil
        }
      }
      let resolved = optionalRead("Resolved state") { try store.loadResolved() }
      let watch = optionalRead("Subscription baselines") { try store.loadWatch() }
      let inventory = optionalRead("Skill inventory") {
        let managed = try SkillOperations.listManaged(
          scope: scope.installScope, environment: runtime)
        let installed = try SkillOperations.listInstalled(
          scope: scope.installScope, environment: runtime)
        var seen = Set<InventoryItem.ID>()
        return (managed + installed).compactMap { skill -> InventoryItem? in
          let id = InventoryItem.ID(
            name: skill.name, agent: skill.agent, scope: skill.scope, path: skill.path)
          guard seen.insert(id).inserted else { return nil }
          return InventoryItem(
            id: id, status: skill.status.rawValue,
            mode: skill.mode?.rawValue, source: skill.sourceIdentity)
        }
      }
      if let report = optionalRead(
        "Skill diagnostics",
        {
          try SkillOperations.doctor(scope: scope.installScope, environment: runtime)
        })
      {
        diagnostics += report.checks.map {
          AppDiagnostic(
            scope: scope, operation: "Skills", severity: $0.status == .error ? .error : .warning,
            message: "\($0.id): \($0.message)", path: $0.path)
        }
      }
      if let report = optionalRead(
        "Instruction diagnostics",
        {
          try InstructionOperations.doctor(scope: scope.installScope, environment: runtime)
        })
      {
        diagnostics += report.diagnostics.map {
          AppDiagnostic(
            scope: scope, operation: "Instructions", severity: .warning,
            message: "\($0.kind.rawValue): \($0.message)", path: $0.path?.path)
        }
      }
      let ownInstructions: [OwnInstructionItem]? =
        scope.kind == .project
        ? optionalRead("Local instructions") {
          try InstructionOperations.listOwn(environment: runtime).map { unit in
            OwnInstructionItem(
              id: .init(source: unit.record.source, name: unit.record.name, path: unit.record.path),
              heading: unit.section.heading, description: unit.section.description,
              paths: unit.section.paths, hash: unit.record.hash,
              authorFile: scope.root.appendingPathComponent(unit.record.path))
          }
        } : nil
      let mappings = InstructionOperations.export(
        projectRoots: scope.kind == .project ? [scope.root] : [], environment: runtime
      ).map { Self.mapping($0) }
      let defaults = Declaration(
        agents: document?.declaration.defaultAgents?.compactMap(AgentID.init(rawValue:))
      )
      .defaultAgents
      let snapshot = WorkspaceSnapshot(
        scope: scope, manifestURL: store.declarationURL, resolvedURL: store.resolvedURL,
        watchURL: store.watchURL, document: document, effectiveDefaultAgents: defaults,
        items: document.map(Self.items) ?? [], inventory: inventory, resolved: resolved,
        watch: watch,
        mappings: mappings, ownInstructions: ownInstructions, diagnostics: diagnostics,
        readAt: Date())
      return CoreCompletion(disposition: .completed, snapshot: snapshot, diagnostics: [])
    } catch {
      return CoreCompletion(
        disposition: .failed, snapshot: nil,
        diagnostics: Self.diagnostics(error, scope: scope, operation: "Read configuration"))
    }
  }

  static func diagnostics(_ error: any Error, scope: WorkspaceScope, operation: String)
    -> [AppDiagnostic]
  {
    if let issue = error as? ProjectRootUnavailable {
      return [
        AppDiagnostic(
          scope: scope, operation: operation, message: issue.message, path: issue.root.path)
      ]
    }
    if let failure = error as? ManifestFailure {
      return failure.diagnostics.map {
        AppDiagnostic(
          scope: scope, operation: operation,
          message: "\($0.code): \($0.message) (line \($0.span.line), column \($0.span.column))")
      }
    }
    let message: String
    if let error = error as? CoreError {
      message = error.description
    } else if let error = error as? InstructionError {
      message = error.description
    } else {
      message = error.localizedDescription
    }
    return [AppDiagnostic(scope: scope, operation: operation, message: message)]
  }

  static func items(_ document: DeclarationDocument) -> [DeclarationItem] {
    var output: [DeclarationItem] = []
    func append(
      _ records: [DeclarationRecord], at base: String, category: String, container: String
    ) {
      for (index, record) in records.enumerated() {
        let pointer = base + "/\(index)"
        guard let node = document.node(at: pointer) else { continue }
        let title =
          record["name"]?.string ?? record["source"]?.string ?? DeclarationLabels.kind(record.kind)
        output.append(
          DeclarationItem(
            id: node, pointer: pointer, title: title,
            category: category, record: record, container: container))
      }
    }
    let ir = document.declaration
    append(ir.sources, at: "/sources", category: "Source", container: "Scope")
    append(ir.components, at: "/components", category: "Component", container: "Scope")
    append(ir.groups, at: "/groups", category: "Group", container: "Scope")
    append(ir.uses, at: "/uses", category: "Group Reference", container: "Scope")
    for (index, group) in ir.groups.enumerated() {
      let name = group["name"]?.string ?? "Group"
      append(
        group["components"]?.elements?.compactMap(\.record) ?? [],
        at: "/groups/\(index)/components", category: "Component", container: name)
      append(
        group["uses"]?.elements?.compactMap(\.record) ?? [],
        at: "/groups/\(index)/uses", category: "Group Reference", container: name)
    }
    return output
  }

  static func mapping(_ value: InstructionMapping, rootIssue: AppDiagnostic? = nil) -> MappingItem {
    let status: String
    if let rootIssue {
      status = "Unavailable: " + rootIssue.message
    } else {
      switch value.status {
      case .locked: status = "Locked mapping; disk status is reported in Diagnostics"
      case .missingLock: status = "No resolved instruction mapping"
      case .pendingRecovery: status = "Recovery pending"
      case .unavailable(let reason): status = "Unavailable: " + reason
      }
    }
    return MappingItem(
      id: value.scope.rawValue + ":" + value.root.path,
      title: value.scope == .user ? "User Configuration" : value.root.lastPathComponent,
      scope: WorkspaceScope(kind: value.scope == .user ? .user : .project, root: value.root),
      status: status,
      targets: value.targets.map {
        MappingTarget(
          id: $0.target, agents: $0.agents.map(\.displayName).joined(separator: ", "),
          sections: $0.sections.map { $0.source + ":" + $0.name }, importedFile: $0.import)
      }, unplaced: value.unplaced.map { $0.source + ":" + $0.name },
      prompts: value.prompts.mapValues { $0.map { $0.source + ":" + $0.name } })
  }
}
