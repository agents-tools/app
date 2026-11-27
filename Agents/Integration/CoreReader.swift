import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsUpdates
import Foundation

struct CoreReader: Sendable {
  let home: URL
  let processEnvironment: [String: String]

  var policyFiles: [String: String] = [:]

  private func environment(for scope: WorkspaceScope) -> RuntimeEnvironment {
    CoreActions(home: home, processEnvironment: processEnvironment, policyFiles: policyFiles)
      .environment(for: scope)
  }

  func readUserSkillReferences() -> CoreCompletion {
    let scope = WorkspaceScope(kind: .user, root: home)
    let runtime = environment(for: scope)
    let store = StateStore(scope: .user, environment: runtime)
    let dependencies = Self.stateDependencies(store: store)
    do {
      let inspection = try UpdateOperations.inspect(scope: .user, environment: runtime)
      let skills = Self.skillWorkspace(inspection, scope: scope, store: store)
      return .init(disposition: .completed, output: .userSkillReferences(skills.items),
                   readDependencies: dependencies + skills.dependencies + inspection.readLocations.map(ReadDependency.subtree))
    } catch {
      return .init(disposition: .failed, diagnostics: Self.diagnostics(error, scope: scope, operation: "Read user skills"),
                   readDependencies: dependencies)
    }
  }

  func read(scope: WorkspaceScope) -> CoreCompletion {
    let runtime = environment(for: scope)
    let store = StateStore(scope: scope.installScope, environment: runtime)
    do {
      try ProjectRootAccess.requireAvailable(scope)
      let inspection = try UpdateOperations.inspect(scope: scope.installScope, environment: runtime)
      let document = inspection.document
      var diagnostics =
        document?.diagnostics.map {
          AppDiagnostic(
            scope: scope, operation: "Manifest",
            severity: $0.severity == .error ? .error : .warning,
            message: "\($0.code): \($0.message) (line \($0.span.line), column \($0.span.column))",
            path: store.declarationURL.path)
        } ?? []
      if inspection.recovery.pending {
        diagnostics.append(
          AppDiagnostic(
            scope: scope, operation: "Recovery",
            message: inspection.recovery.diagnostic ?? "Recovery is pending.",
            blocksTermination: inspection.recovery.requiresOwner, coreRecovery: true))
      }
      if inspection.pendingMarketplaceDeployment != nil {
        diagnostics.append(
          AppDiagnostic(scope: scope, operation: "Package lock", severity: .warning,
                        message: "Open Manage Packages to review the pending deployment."))
      }
      if let issue = inspection.marketplaceIssue {
        diagnostics.append(
          AppDiagnostic(
            scope: scope, operation: "Package lock", severity: .error,
            message: issue.description, path: store.declarationURL.path))
      }
      for deployment in inspection.deployments where deployment.status != .current {
        diagnostics.append(
          AppDiagnostic(
            scope: scope, operation: "Deployment", severity: .warning,
            message: deployment.diagnostic ?? deployment.status.rawValue,
            path: deployment.location.path))
      }
      let skills = Self.skillWorkspace(inspection, scope: scope, store: store)
      var readDependencies = inspection.readLocations.map(ReadDependency.subtree)
        + skills.dependencies
      readDependencies.append(.entry(SourceAccessSettingsEditor.settingsURL(environment: runtime)))
      var ownInstructions: [OwnInstructionItem]?
      if scope.kind == .project {
        do {
          let own = try InstructionOperations.inspectOwnInstructions(environment: runtime)
          readDependencies += own.readLocations.map(ReadDependency.subtree)
          ownInstructions = own.units.map { unit in
            OwnInstructionItem(
              id: .init(source: unit.record.source, name: unit.record.name, path: unit.record.path),
              heading: unit.section.heading, description: unit.section.description,
              paths: unit.section.paths, hash: unit.record.hash,
              authorFile: scope.root.appendingPathComponent(unit.record.path))
          }
        } catch {
          diagnostics += Self.diagnostics(error, scope: scope, operation: "Local instructions")
          // A failed inspection has no read locations to report. Keep observing its input.
          let directory = runtime.projectDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(store.directory.lastPathComponent)
            .appendingPathComponent("instructions")
          readDependencies.append(.subtree(directory))
        }
      }
      let mappingValues = InstructionOperations.export(
        projectRoots: scope.kind == .project ? [scope.root] : [], environment: runtime
      )
      readDependencies += mappingValues.flatMap(\.readDependencies)
      let mappings = mappingValues.map { Self.mapping($0) }
      let defaults = inspection.declaration?.defaultAgents ?? Declaration().defaultAgents
      let snapshot = WorkspaceSnapshot(
        scope: scope, manifestURL: store.declarationURL, resolvedURL: store.resolvedURL,
        watchURL: store.watchURL, document: document, effectiveDefaultAgents: defaults,
        items: document.map(Self.items) ?? [], inventory: skills.inventory, inspection: inspection,
        watch: inspection.watch,
        mappings: mappings, ownInstructions: ownInstructions, diagnostics: diagnostics,
        readAt: Date(), skillWorkspaceItems: skills.items)
      return CoreCompletion(
        disposition: .completed, snapshot: snapshot, diagnostics: [],
        readDependencies: readDependencies)
    } catch {
      var diagnostics = Self.diagnostics(error, scope: scope, operation: "Read configuration")
      if scope.kind == .user {
        do {
          if try ExistingGlobalConfiguration.isAvailable(environment: runtime) {
            return CoreCompletion(disposition: .completed, output: .existingConfigurationAvailable)
          }
        } catch {
          diagnostics.append(
            AppDiagnostic(
              scope: scope, operation: "Check for existing configuration",
              message: error.localizedDescription))
        }
      }
      return CoreCompletion(
        disposition: .failed, snapshot: nil, diagnostics: diagnostics)
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
    } else if let described = error as? any CustomStringConvertible {
      message = described.description
    } else {
      message = error.localizedDescription
    }
    return [AppDiagnostic(scope: scope, operation: operation, message: message)]
  }

  func stateDependencies(scope: WorkspaceScope) -> [ReadDependency] {
    Self.stateDependencies(
      store: StateStore(
        scope: scope.installScope,
        environment: environment(for: scope)))
  }

  static func stateDependencies(store: StateStore) -> [ReadDependency] {
    var dependencies = [store.declarationURL, store.resolvedURL, store.watchURL]
      .map(ReadDependency.subtree)
    dependencies.append(
      .entry(SourceAccessSettingsEditor.settingsURL(environment: store.environment)))
    var selections = [store.environment.userOrganizationPolicy]
    if store.scope == .project { selections.append(store.environment.projectOrganizationPolicy) }
    for selection in selections {
      if case .local(let url) = selection?.source { dependencies.append(.entry(url)) }
    }
    if store.scope == .user {
      dependencies.append(
        .entry(ExistingConfigurationSession.existingDeclaration(in: store.directory)))
    }
    return dependencies
  }

  static func sectionItems(_ document: DeclarationDocument) -> [DeclarationItem] {
    var result: [DeclarationItem] = []
    func appendSections(_ values: [DeclarationValue], at base: String, title: String) {
      for (index, value) in values.enumerated() {
        let pointer = base + "/sections/\(index)"
        guard let node = document.node(at: pointer), let record = value.record else { continue }
        result.append(
          .init(
            id: node, pointer: pointer,
            title: record["name"]?.string ?? "Section", category: "Section", record: record,
            container: title))
      }
    }
    for component in items(document) where component.record.kind == "instructions" {
      appendSections(
        component.record["sections"]?.elements ?? [], at: component.pointer, title: component.title)
      for (index, value) in (component.record["chatGPT"]?.elements ?? []).enumerated() {
        guard let prompt = value.record else { continue }
        appendSections(
          prompt["sections"]?.elements ?? [], at: component.pointer + "/chatGPT/\(index)",
          title: prompt["name"]?.string ?? "Prompt")
      }
    }
    return result
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
      case .locked: status = "From installation lock"
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
          id: $0.target, recipients: $0.agents,
          sections: $0.sections, importedFile: $0.import)
      }, unplaced: value.unplaced,
      prompts: value.prompts)
  }
}
