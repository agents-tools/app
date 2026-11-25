import AgentsCore
import AgentsInstructions
import AgentsUpdates
import Foundation

extension CoreActions {
  func discover(id: UUID, scope: WorkspaceScope, declaration: Declaration) -> CoreCompletion {
    do {
      try ProjectRootAccess.requireAvailable(scope)
      let result = try UpdateOperations.discover(
        declaration, scope: scope.installScope,
        environment: environment(for: scope))
      return CoreCompletion(
        disposition: .completed, output: .discovery(id, result),
        readDependencies: result.readLocations.map(ReadDependency.subtree))
    } catch {
      return CoreCompletion(
        disposition: .failed,
        diagnostics: CoreReader.diagnostics(
          error, scope: scope, operation: "Discover declared components"))
    }
  }

  func preview(_ proposal: UpdateProposal) -> CoreCompletion {
    do {
      try ProjectRootAccess.requireAvailable(proposal.scope)
      let report: CombinedUpdateReport
      switch proposal.contents {
      case .update(let request):
        report = try UpdateOperations.preview(
          request, scope: proposal.scope.installScope,
          environment: environment(for: proposal.scope))
      case .packageRequest(let request, let intent):
        let review = try UpdateOperations.previewLifecycle(
          request, intent: intent, scope: proposal.scope.installScope,
          environment: environment(for: proposal.scope))
        return try packagePreview(
          .init(review, scope: proposal.scope, report: \.self), proposal: proposal)
      case .instructionCompilation:
        let review = try InstructionOperations.previewCompilation(
          scope: proposal.scope.installScope, environment: environment(for: proposal.scope))
        return try packagePreview(
          .init(review, scope: proposal.scope, report: \.self), proposal: proposal)
      case .packageReview(let review):
        return try packagePreview(review, proposal: proposal)
      }
      return CoreCompletion(
        disposition: .completed, output: .updatePreview(proposal.id, report),
        readDependencies: report.readLocations.map(ReadDependency.subtree))
    } catch {
      return CoreCompletion(
        disposition: .failed,
        diagnostics: CoreReader.diagnostics(
          error, scope: proposal.scope, operation: proposal.title))
    }
  }

  private func packagePreview(_ review: PackageUpdateReview, proposal: UpdateProposal) throws
    -> CoreCompletion
  {
    guard review.scope == proposal.scope, review.report.scope == proposal.scope.installScope else {
      throw CoreError.invalidState("This package review belongs to another scope.")
    }
    if let conflict = review.ownershipConflict { throw CoreError.invalidState(conflict) }
    return CoreCompletion(
      disposition: .completed, output: .packageUpdatePreview(proposal.id, review),
      readDependencies: review.report.readLocations.map(ReadDependency.subtree))
  }

  func apply(
    _ proposal: UpdateProposal, fingerprint: String, admission: OperationAdmission,
    bindings: [String: Data] = [:], recoveryOnly: Bool = false
  )
    -> CoreCompletion
  {
    do { try ProjectRootAccess.requireAvailable(proposal.scope) } catch {
      return CoreCompletion(
        disposition: .failed,
        diagnostics: CoreReader.diagnostics(
          error, scope: proposal.scope, operation: proposal.title))
    }
    // Preparation, comparison and publication stay on this worker and inside one Core lifetime.
    let confirm: (PreparedUpdate) throws -> Bool = { update in
      guard !recoveryOnly, admission.begin() else { return false }
      _ = try update.apply(ifUnchangedFrom: fingerprint)
      return true
    }
    let provider = EphemeralBindings(values: bindings)
    let completion: UpdateCompletion<Bool>
    switch proposal.contents {
    case .update(let request):
      completion = UpdateOperations.perform(
        request, scope: proposal.scope.installScope,
        environment: environment(for: proposal.scope), bindingProvider: provider, confirm)
    case .packageRequest, .instructionCompilation, .packageReview:
      return Self.operationFailure(
        CoreError.invalidState("Review the package actions before applying."),
        scope: proposal.scope, title: proposal.title)
    }
    return Self.finishUpdate(
      completion, scope: proposal.scope, title: proposal.title,
      cancelledBeforeApply: { !$0 && !recoveryOnly })
  }

  static func performPackage<Report: Sendable, Value: Sendable>(
    _ review: LifecyclePackageReview<Report, Value>, scope: WorkspaceScope, title: String,
    bindings: EphemeralBindings? = nil, output: ((Value) -> ContentOutput)? = nil
  ) async -> CoreCompletion {
    if Task.isCancelled { return .cancelled }
    switch await UpdateOperations.perform(review, bindingProvider: bindings) {
    case .alreadyRunning:
      return operationFailure(
        CoreError.invalidState("This package operation is already running."),
        scope: scope, title: title)
    case .completed(let result):
      return finishUpdate(
        result.package, scope: scope, title: title, packageActions: result.pre + result.post,
        output: output)
    }
  }

  static func operationFailure(_ error: any Error, scope: WorkspaceScope, title: String)
    -> CoreCompletion
  {
    CoreCompletion(
      disposition: .failed,
      diagnostics: CoreReader.diagnostics(error, scope: scope, operation: title))
  }

  private static func finishUpdate<Value>(
    _ completion: UpdateCompletion<Value>, scope: WorkspaceScope, title: String,
    packageActions: [LifecycleActionResult] = [],
    cancelledBeforeApply: (Value) -> Bool = { _ in false },
    output: ((Value) -> ContentOutput)? = nil
  ) -> CoreCompletion {
    let succeeded: Bool
    let cancelled: Bool
    var resultOutput: ContentOutput?
    var diagnostics: [AppDiagnostic] = []
    switch completion.result {
    case .success(let applied):
      succeeded = true
      cancelled = cancelledBeforeApply(applied)
      resultOutput = output?(applied)
    case .failure(let error):
      succeeded = false
      let underlying = (error as? UpdateApplyError)?.underlyingError ?? error
      cancelled =
        underlying is CancellationError && completion.disposition == .unchanged
        && !completion.recovery.pending
      if !cancelled {
        diagnostics += CoreReader.diagnostics(underlying, scope: scope, operation: title)
      }
    }
    let terminal = UpdateTerminal(
      disposition: completion.disposition,
      recoveredBeforePreparation: completion.recoveredBeforePreparation,
      recovery: completion.recovery, succeeded: succeeded, cancelledBeforeApply: cancelled,
      packageActions: packageActions)
    diagnostics.append(
      AppDiagnostic(
        scope: scope, operation: title,
        severity: completion.recovery.pending ? .error : .information,
        message: terminal.message, blocksTermination: completion.recovery.pending,
        coreRecovery: true))
    if let message = completion.recovery.diagnostic {
      diagnostics.append(
        AppDiagnostic(
          scope: scope, operation: title,
          message: message, blocksTermination: completion.recovery.pending, coreRecovery: true))
    }
    return CoreCompletion(
      disposition: cancelled ? .cancelled : (succeeded ? .completed : .failed),
      diagnostics: diagnostics, output: resultOutput,
      updateTerminal: terminal)
  }
}

struct EphemeralBindings: RuntimeBindingProvider, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let values: [String: Data]
  var description: String { "<runtime input>" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
  func value(for binding: String, environment: RuntimeEnvironment) throws -> Data {
    guard let value = values[binding] else {
      throw CoreError.invalidState("Required runtime input was not supplied.")
    }
    return value
  }
}
