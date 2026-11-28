import AgentsCore
import AgentsSkills
import AgentsUpdates
import Foundation

extension CoreActions {
  func describeCreation(_ request: CreationRequest) -> CoreCompletion {
    do {
      try ProjectRootAccess.requireAvailable(request.scope)
      let description: InitializationDescription
      let runtime = environment(for: request.scope)
      switch request.kind {
      case .instructions:
        guard request.scope.kind == .project else {
          throw CoreError.unsupported("Local instructions can only be created in a project.")
        }
        description = try UpdateOperations.describeInstructionsInitialization(
          named: request.name, environment: runtime)
      case .skill:
        let name = request.name.isEmpty ? nil : request.name
        if request.scope.kind == .project && request.directory == request.scope.root {
          description = try UpdateOperations.describeProjectSkillInitialization(
            named: name, environment: runtime)
        } else {
          description = try UpdateOperations.describeSkillInitialization(
            named: name, directory: request.directory, environment: runtime)
        }
      }
      return .init(
        disposition: .completed, output: .creationDescription(request.id, description),
        readDependencies: description.readLocations.map(ReadDependency.subtree))
    } catch { return failure(error, scope: request.scope, title: "Review starter content") }
  }

  func initialize(_ description: InitializationDescription, request: CreationRequest)
    -> CoreCompletion
  {
    do { try ProjectRootAccess.requireAvailable(request.scope) } catch {
      return failure(error, scope: request.scope, title: "Create " + request.kind.title)
    }
    let completion = UpdateOperations.initialize(description)
    return completed(completion, scope: request.scope, title: "Create " + request.kind.title) {
      .created(request, $0)
    }
  }

  func watchPreview(id: UUID, scope: WorkspaceScope, source: String, removing: Bool)
    -> CoreCompletion
  {
    do {
      let operations = SkillOperations.watchOperations()
      let preview =
        try removing
        ? operations.previewRemove(
          source, scope: scope.installScope, environment: environment(for: scope))
        : operations.previewAdd(
          source, scope: scope.installScope, environment: environment(for: scope))
      return .init(
        disposition: .completed, output: .watchPreview(id, preview),
        readDependencies: preview.readLocations.map(ReadDependency.subtree))
    } catch { return failure(error, scope: scope, title: "Review subscription") }
  }

  func applyWatch(_ preview: WatchMutationPreview, scope: WorkspaceScope) -> CoreCompletion {
    completed(UpdateOperations.performWatch(preview), scope: scope, title: "Change subscription") {
      _ in nil
    }
  }

  func acknowledgeWatch(_ status: WatchStatus, scope: WorkspaceScope) -> CoreCompletion {
    completed(
      UpdateOperations.performWatch(status), scope: scope, title: "Mark subscription as read"
    ) {
      _ in nil
    }
  }

  func inspectClients(id: UUID) -> CoreCompletion {
    do {
      let scope = WorkspaceScope(kind: .user, root: home)
      let report = try AgentClientOperations.inspect(environment: environment(for: scope))
      return .init(disposition: .completed, output: .clientInspection(id, report))
    } catch {
      return .init(
        disposition: .failed, output: .clientInspectionFailed(id, String(describing: error)))
    }
  }

  func inspectImport(
    id: UUID, scope: WorkspaceScope, file: URL, format: String, inputRoot: URL? = nil
  ) -> CoreCompletion {
    do {
      let root = inputRoot ?? file.deletingLastPathComponent()
      let rootParts = root.standardizedFileURL.pathComponents
      let fileParts = file.standardizedFileURL.pathComponents
      guard fileParts.count > rootParts.count, fileParts.starts(with: rootParts) else {
        throw CoreError.invalidSource("Choose an input file inside the selected input directory.")
      }
      let document = fileParts.dropFirst(rootParts.count).joined(separator: "/")
      let value = try SourceImportOperations.inspect(
        format: format, root: root, document: document)
      return .init(
        disposition: .completed, output: .sourceImport(id, value),
        readDependencies: value.readLocations.map(ReadDependency.subtree))
    } catch { return failure(error, scope: scope, title: "Inspect import") }
  }

  func watchStatus(id: UUID, scope: WorkspaceScope, source: String?) -> CoreCompletion {
    do {
      try ProjectRootAccess.requireAvailable(scope)
      let operations = SkillOperations.watchOperations()
      let values: [WatchStatus]
      let locations: [URL]
      if let source {
        let status = try operations.diff(
          source, scope: scope.installScope, environment: environment(for: scope))
        values = [status]
        locations = status.readLocations
      } else {
        let inspection = try operations.inspectStatus(
          scope: scope.installScope, environment: environment(for: scope))
        values = inspection.statuses
        locations = inspection.readLocations
      }
      return .init(
        disposition: .completed, output: .watchStatus(id, values),
        readDependencies: locations.map(ReadDependency.subtree))
    } catch { return failure(error, scope: scope, title: "Check subscriptions") }
  }

  func importRequest(
    id: UUID, scope: WorkspaceScope, imported: SourceImportInspection, inspection: ScopeInspection
  ) -> CoreCompletion {
    do {
      return .init(
        disposition: .completed,
        output: .importRequest(id, try imported.updateRequest(in: inspection)))
    } catch { return failure(error, scope: scope, title: "Review import") }
  }

  func connectionSnapshot(id: UUID, scope: WorkspaceScope, selection: ComponentSelection)
    -> CoreCompletion
  {
    do {
      let value = try MCPConnectionOperations.snapshot(
        selection: selection, scope: scope.installScope, environment: environment(for: scope))
      return .init(
        disposition: .completed,
        output: .connectionSnapshot(id, value, MCPConnectionOperations.describe(value)),
        readDependencies: value.readDependencies)
    } catch {
      // Preparation failures can include input paths; connection diagnostics expose only the typed boundary.
      return .init(
        disposition: .failed,
        diagnostics: [
          .init(
            scope: scope, operation: "Prepare connection test",
            message:
              "The selected managed connection could not be prepared. Refresh and select it again.")
        ])
    }
  }

  func failure(_ error: any Error, scope: WorkspaceScope, title: String) -> CoreCompletion {
    .init(
      disposition: .failed,
      diagnostics: CoreReader.diagnostics(error, scope: scope, operation: title))
  }

  func completed<Value: Sendable>(
    _ completion: UpdateCompletion<Value>, scope: WorkspaceScope, title: String,
    output: (Value) -> ContentOutput?
  ) -> CoreCompletion {
    var messages: [AppDiagnostic] = []
    let succeeded: Bool
    let value: ContentOutput?
    switch completion.result {
    case .success(let result):
      succeeded = true
      value = output(result)
    case .failure(let error):
      succeeded = false
      value = nil
      messages = CoreReader.diagnostics(error, scope: scope, operation: title)
    }
    let terminal = UpdateTerminal(
      disposition: completion.disposition,
      recoveredBeforePreparation: completion.recoveredBeforePreparation,
      recovery: completion.recovery, succeeded: succeeded, cancelledBeforeApply: false)
    messages.append(
      .init(
        scope: scope, operation: title,
        severity: completion.recovery.pending ? .error : .information, message: terminal.message,
        blocksTermination: completion.recovery.pending, coreRecovery: true))
    if let diagnostic = completion.recovery.diagnostic {
      messages.append(
        .init(
          scope: scope, operation: title, message: diagnostic,
          blocksTermination: completion.recovery.pending, coreRecovery: true))
    }
    return .init(
      disposition: succeeded ? .completed : .failed, diagnostics: messages, output: value,
      updateTerminal: terminal)
  }
}
