import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation

extension SourceAccessSelection {
  func inspect(environment: RuntimeEnvironment) -> CoreCompletion {
    let result: Result<SourceAccessInspection, SourceAccessIssue>
    var dependencies: [ReadDependency] = []
    do {
      let policy = try readPolicy(environment: environment)
      dependencies = policy.readDependencies
      let report = try report(environment: environment, policy: policy.effective)
      result = .success(.init(report: report, policy: policy.effective))
    } catch {
      result = .failure(issue(for: error))
    }
    return CoreCompletion(
      disposition: .completed, output: .sourceAccessInspection(result),
      readDependencies: dependencies)
  }

  func validate(
    inspection: SourceAccessInspection, environment: RuntimeEnvironment,
    admission: OperationAdmission
  ) -> CoreCompletion {
    let result: Result<SourceCredentialReport.Validation, SourceAccessIssue>
    do {
      try ProjectRootAccess.requireAvailable(id.scope)
      let store = StateStore(scope: id.scope.installScope, environment: environment)
      guard try store.loadManifest()?.digest == documentDigest else {
        throw SourceAccessIssue.inputsChanged
      }
      let policy = try readPolicy(environment: environment).effective
      let report = try report(environment: environment, policy: policy)
      guard inspection.mayValidate, policy == inspection.policy, report == inspection.report else {
        throw SourceAccessIssue.inputsChanged
      }
      // Linearize admission after the offline preflight. The synchronous Core call owns
      // its request until it returns.
      guard admission.begin() else { return .cancelled }
      let checked = try SourceCredentialOperations.validate(
        source: selector, declaration: declaration, environment: environment, policy: policy)
      result = .success(checked.validation ?? .indeterminate)
    } catch {
      result = .failure(issue(for: error))
    }
    return .init(disposition: .completed, output: .sourceAccessValidation(result))
  }

  private func report(environment: RuntimeEnvironment, policy: EffectiveSourcePolicy) throws
    -> SourceCredentialReport
  {
    // The selector parser trims its input. Keep an alias from resolving to another source.
    guard selector == selector.trimmingCharacters(in: .whitespacesAndNewlines) else {
      throw SourceAccessIssue.unsupportedAlias
    }
    return try SourceCredentialOperations.inspect(
      source: selector, declaration: declaration, environment: environment, policy: policy)
  }

  private func readPolicy(environment: RuntimeEnvironment) throws -> SourcePolicyInspection {
    do {
      return try SourcePolicyOperations.inspect(
        scope: id.scope.installScope, environment: environment)
    } catch {
      throw SourceAccessIssue.policyUnreadable
    }
  }

  private func issue(for error: any Error) -> SourceAccessIssue {
    if let issue = error as? SourceAccessIssue { return issue }
    if error is SourcePolicyFailure { return .policyDenied }
    if let error = error as? SourceAccessError { return .access(error) }
    return .unavailable
  }
}
