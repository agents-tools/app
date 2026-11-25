import AgentsCore
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
      case .bundle(let preview):
        if let conflict = preview.ownershipConflict { throw CoreError.invalidState(conflict) }
        report = preview.report
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
    case .bundle(let preview):
      completion = BundleOperations.performImport(preview, bindingProvider: provider, confirm)
    }
    let succeeded: Bool
    let cancelled: Bool
    var diagnostics: [AppDiagnostic] = []
    switch completion.result {
    case .success(let applied):
      succeeded = true
      cancelled = !applied && !recoveryOnly
    case .failure(let error):
      succeeded = false
      cancelled = false
      let underlying = (error as? UpdateApplyError)?.underlyingError ?? error
      diagnostics += CoreReader.diagnostics(
        underlying, scope: proposal.scope, operation: proposal.title)
    }
    let terminal = UpdateTerminal(
      disposition: completion.disposition,
      recoveredBeforePreparation: completion.recoveredBeforePreparation,
      recovery: completion.recovery, succeeded: succeeded, cancelledBeforeApply: cancelled)
    diagnostics.append(
      AppDiagnostic(
        scope: proposal.scope, operation: proposal.title,
        severity: completion.recovery.pending ? .error : .information,
        message: terminal.message, blocksTermination: completion.recovery.pending,
        coreRecovery: true))
    if let message = completion.recovery.diagnostic {
      diagnostics.append(
        AppDiagnostic(
          scope: proposal.scope, operation: proposal.title,
          message: message, blocksTermination: completion.recovery.pending, coreRecovery: true))
    }
    return CoreCompletion(
      disposition: cancelled ? .cancelled : (succeeded ? .completed : .failed),
      diagnostics: diagnostics,
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
