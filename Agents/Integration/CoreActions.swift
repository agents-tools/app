import AgentsCore
import AgentsInstructions
import AgentsManifest
import AgentsSkills
import Foundation

struct CoreActions: Sendable {
  let home: URL
  let processEnvironment: [String: String]

  func create(_ request: CreationRequest) -> CoreCompletion {
    do {
      let url: URL
      switch request.kind {
      case .skill:
        url = try SkillOperations.initializeSkill(
          named: request.name.isEmpty ? nil : request.name, directory: request.directory)
      case .instructions:
        guard request.scope.kind == .project else {
          throw CoreError.unsupported("Local instructions can only be created in a project.")
        }
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
          operation: "Create " + request.kind.title))
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

  func validate(_ request: DraftValidationRequest) -> CoreCompletion {
    do {
      let change = try request.document.preparing(request.edits)
      let message =
        change.delta.changedPointers.isEmpty
        ? "This draft does not change the declaration."
        : "The draft is valid for this declaration snapshot. It has not been applied."
      return CoreCompletion(disposition: .completed, output: .validatedDraft(request.id, message))
    } catch {
      return CoreCompletion(
        disposition: .failed,
        diagnostics: CoreReader.diagnostics(
          error, scope: request.scope, operation: "Validate declaration draft"))
    }
  }

  func mappings(_ request: MappingRequest) -> CoreCompletion {
    let values = InstructionOperations.export(
      projectRoots: request.projects, environment: environment(for: request.context))
    let diagnostics = values.compactMap { value -> AppDiagnostic? in
      guard case .unavailable(let reason) = value.status else { return nil }
      return AppDiagnostic(
        scope: .init(kind: value.scope == .user ? .user : .project, root: value.root),
        operation: "Read instruction mapping", message: reason)
    }
    return CoreCompletion(
      disposition: .completed, diagnostics: diagnostics,
      output: .mappings(request.id, values.map(CoreReader.mapping)))
  }

  private func environment(for scope: WorkspaceScope) -> RuntimeEnvironment {
    RuntimeEnvironment(
      projectDirectory: scope.root, homeDirectory: home, environment: processEnvironment)
  }
}
