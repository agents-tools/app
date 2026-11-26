import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import AgentsUpdates
import Foundation

struct CoreActions: Sendable {
  let home: URL
  let processEnvironment: [String: String]
  var policyFiles: [String: String] = [:]

  func create(_ request: CreationRequest) -> CoreCompletion {
    let described = describeCreation(request)
    guard case .creationDescription(_, let description) = described.output else { return described }
    return initialize(description, request: request)
  }

  func render(_ request: PromptRequest) -> CoreCompletion {
    do {
      try ProjectRootAccess.requireAvailable(request.scope)
      let runtime = environment(for: request.scope)
      let bytes: Data
      let dependencies: [ReadDependency]
      switch request.content {
      case .named(let name):
        let export = try InstructionOperations.inspectChatGPTExport(
          prompt: name, scope: request.scope.installScope, environment: runtime)
        bytes = export.bytes
        dependencies = export.readLocations.map(ReadDependency.subtree)
      case .mapped(let target):
        (bytes, dependencies) = try ManagedInstructionOutput.read(
          target, in: request.scope, environment: runtime)
      }
      guard let text = String(data: bytes, encoding: .utf8) else {
        throw InstructionError.invalidUTF8
      }
      return CoreCompletion(
        disposition: .completed, output: .prompt(request, text),
        readDependencies: dependencies
      )
    } catch {
      return CoreCompletion(
        disposition: .failed,
        diagnostics: CoreReader.diagnostics(
          error, scope: request.scope,
          operation: request.title))
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
      output: .mappings(request.id, mappings),
      readDependencies: values.flatMap(\.readDependencies))
  }

  func environment(for scope: WorkspaceScope) -> RuntimeEnvironment {
    var runtime = RuntimeEnvironment(
      projectDirectory: scope.root, homeDirectory: home, environment: processEnvironment)
    let user = WorkspaceScope(kind: .user, root: home)
    if runtime.userOrganizationPolicy == nil, let path = policyFiles[user.id] {
      runtime.userOrganizationPolicy = .init(.local(URL(fileURLWithPath: path)))
    }
    if scope.kind == .project, runtime.projectOrganizationPolicy == nil,
      let path = policyFiles[scope.id]
    {
      runtime.projectOrganizationPolicy = .init(.local(URL(fileURLWithPath: path)))
    }
    return runtime
  }
}
