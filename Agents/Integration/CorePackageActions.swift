import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation

extension CoreActions {
  static func executePackageActionTest(_ review: LifecycleTestReview, scope: WorkspaceScope)
    async -> CoreCompletion
  {
    switch await LifecycleOperations.executeTest(review) {
    case .alreadyRunning:
      return operationFailure(
        CoreError.invalidState("This test is already running."), scope: scope,
        title: "Test Package Actions")
    case .completed(let results):
      return CoreCompletion(
        disposition: .completed, output: .packageActionResults(results))
    }
  }

  static func savePackageActions(
    _ review: LifecycleDeclarationReview, enable: Bool, scope: WorkspaceScope
  ) async -> CoreCompletion {
    let result = await LifecycleOperations.save(review, enable: enable)
    return packageActionCompletion(result, scope: scope, title: "Save Package Actions") {
      .packageActionSave($0)
    }
  }

  static func enablePackageActions(_ review: LifecycleEnableReview, scope: WorkspaceScope)
    async -> CoreCompletion
  {
    let result = await LifecycleOperations.enable(review)
    return packageActionCompletion(result, scope: scope, title: "Enable Package Actions") { _ in nil
    }
  }

  static func revokePackageActions(
    _ project: LifecycleProjectIdentity, scope: WorkspaceScope, environment: RuntimeEnvironment
  ) -> CoreCompletion {
    do {
      try LifecycleOperations.revoke(project, environment: environment)
      return CoreCompletion(disposition: .completed)
    } catch {
      return operationFailure(error, scope: scope, title: "Revoke Package Actions")
    }
  }

  private static func packageActionCompletion<Value: Sendable>(
    _ submission: LifecycleSubmission<Result<Value, any Error>>,
    scope: WorkspaceScope, title: String, output: (Value) -> ContentOutput?
  ) -> CoreCompletion {
    switch submission {
    case .alreadyRunning:
      return operationFailure(
        CoreError.invalidState("This operation is already running."), scope: scope, title: title)
    case .completed(.success(let value)):
      return CoreCompletion(disposition: .completed, output: output(value))
    case .completed(.failure(let error)):
      if error is CancellationError { return .cancelled }
      return operationFailure(error, scope: scope, title: title)
    }
  }
}

struct PackageActionYAML {
  private static let header = "version: 1\n"
  private static let identity = DocumentIdentity("Package Actions")

  static func text(for declaration: DeclarationValue?) throws -> String {
    let template = try parse("")
    let change = try template.preparing([.setLifecycle(declaration)])
    guard change.bytes.starts(with: header.utf8) else {
      throw CoreError.invalidState("The package action YAML could not be displayed.")
    }
    return String(decoding: change.bytes.dropFirst(header.utf8.count), as: UTF8.self)
  }

  static func preview(
    _ text: String, replacing original: DeclarationDocument, scope: WorkspaceScope,
    environment: RuntimeEnvironment
  ) throws -> LifecycleDeclarationReview {
    let draft = try parse(text)
    guard
      !draft.sourceMap.entries.contains(where: {
        !$0.defaulted && !$0.pointer.isEmpty && $0.pointer != "/lifecycle"
          && !$0.pointer.hasPrefix("/lifecycle/")
      })
    else {
      throw CoreError.invalidState("Edit only the lifecycle section in this window.")
    }
    let review = try LifecycleOperations.previewDeclaration(
      draft.declaration.lifecycle, scope: scope.installScope, environment: environment)
    guard review.documentChange.originalDigest == original.digest else {
      throw CoreError.invalidState("The configuration changed. Close the editor and open it again.")
    }
    return review
  }

  private static func parse(_ section: String) throws -> DeclarationDocument {
    try DeclarationDocument(bytes: Array((header + section).utf8), identity: identity)
  }
}
