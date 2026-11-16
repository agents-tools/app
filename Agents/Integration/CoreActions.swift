import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation

struct CoreActions: Sendable {
  let home: URL
  let processEnvironment: [String: String]

  func create(_ request: CreationRequest) -> CoreCompletion {
    do {
      try ProjectRootAccess.requireAvailable(request.scope)
      if request.kind == .instructions, request.scope.kind != .project {
        throw CoreError.unsupported("Local instructions can only be created in a project.")
      }
    } catch {
      return CoreCompletion(
        disposition: .failed,
        diagnostics: CoreReader.diagnostics(
          error, scope: request.scope, operation: "Create " + request.kind.title))
    }
    do {
      let url: URL
      switch request.kind {
      case .skill:
        url = try SkillOperations.initializeSkill(
          named: request.name.isEmpty ? nil : request.name, directory: request.directory)
      case .instructions:
        url = try InstructionOperations.initializeInstructions(
          named: request.name, environment: environment(for: request.scope))
      }
      return CoreCompletion(
        disposition: .completed,
        diagnostics: [
          AppDiagnostic(
            scope: request.scope, operation: "Create " + request.kind.title,
            severity: .information, message: "Created starter content.", path: url.path)
        ], output: .created(request, url))
    } catch {
      return CoreCompletion(
        disposition: .failed,
        diagnostics: CoreReader.diagnostics(
          error, scope: request.scope,
          operation: "Create " + request.kind.title), output: .creationUnconfirmed(request))
    }
  }

  func render(_ request: PromptRequest) -> CoreCompletion {
    do {
      let bytes = try InstructionOperations.renderChatGPT(
        prompt: request.name, scope: request.scope.installScope,
        environment: environment(for: request.scope))
      guard let text = String(data: bytes, encoding: .utf8) else {
        throw InstructionError.invalidUTF8
      }
      return CoreCompletion(disposition: .completed, output: .prompt(request, text))
    } catch {
      return CoreCompletion(
        disposition: .failed,
        diagnostics: CoreReader.diagnostics(
          error, scope: request.scope,
          operation: "Generate prompt “\(request.name)”"))
    }
  }

  func mappings(_ request: MappingRequest) -> CoreCompletion {
    let values = InstructionOperations.export(
      projectRoots: request.projects, environment: environment(for: request.context))
    var diagnostics: [AppDiagnostic] = []
    let mappings = values.map { value in
      let scope = WorkspaceScope(kind: value.scope == .user ? .user : .project, root: value.root)
      var rootIssue: AppDiagnostic?
      do {
        try ProjectRootAccess.requireAvailable(scope)
      } catch {
        let issues = CoreReader.diagnostics(
          error, scope: scope, operation: "Read instruction mapping")
        diagnostics += issues
        rootIssue = issues.first
      }
      if case .unavailable(let reason) = value.status {
        diagnostics.append(
          AppDiagnostic(scope: scope, operation: "Read instruction mapping", message: reason))
      }
      return CoreReader.mapping(value, rootIssue: rootIssue)
    }
    return CoreCompletion(
      disposition: .completed, diagnostics: diagnostics,
      output: .mappings(request.id, mappings))
  }

  func environment(for scope: WorkspaceScope) -> RuntimeEnvironment {
    RuntimeEnvironment(
      projectDirectory: scope.root, homeDirectory: home, environment: processEnvironment)
  }
}
