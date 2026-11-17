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
    let described = describeCreation(request)
    guard case .creationDescription(_, let description) = described.output else { return described }
    return initialize(description, request: request)
  }

  func render(_ request: PromptRequest) -> CoreCompletion {
    do {
      let export = try InstructionOperations.inspectChatGPTExport(
        prompt: request.name, scope: request.scope.installScope,
        environment: environment(for: request.scope))
      guard let text = String(data: export.bytes, encoding: .utf8) else {
        throw InstructionError.invalidUTF8
      }
      return CoreCompletion(
        disposition: .completed, output: .prompt(request, text), readLocations: export.readLocations
      )
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
