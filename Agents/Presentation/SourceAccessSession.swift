import AgentsCore
import AgentsManifest
import Foundation

struct SourceAccessSelection: Sendable {
  struct ID: Equatable, Sendable {
    let scope: WorkspaceScope
    let node: NodeID
    let readAt: Date
    let presentation: UUID
  }

  let id: ID
  let selector: String
  let declaration: Declaration
  let documentDigest: String

  init?(snapshot: WorkspaceSnapshot, node: NodeID, presentation: UUID) {
    guard let item = snapshot.sources.first(where: { $0.id == node }),
      let alias = item.record["name"]?.string,
      let declaration = snapshot.inspection.declaration, declaration.sources[alias] != nil,
      let document = snapshot.document
    else { return nil }
    id = ID(scope: snapshot.scope, node: node, readAt: snapshot.readAt, presentation: presentation)
    selector = alias
    self.declaration = declaration
    documentDigest = document.digest
  }
}

struct SourceAccessInspection: Sendable {
  let report: SourceCredentialReport
  let policy: EffectiveSourcePolicy

  var mayValidate: Bool {
    report.transport == .https && report.provider != nil && report.availability == .available
  }
}

enum SourceAccessIssue: Error, Sendable, Equatable {
  case inputsChanged
  case policyUnreadable
  case policyDenied
  case access(SourceAccessError)
  case unsupportedAlias
  case unavailable
}

struct SourceAccessSession {
  let selection: SourceAccessSelection.ID
  var inspection: Result<SourceAccessInspection, SourceAccessIssue>?
  var validationOperation: UUID?
  var validation: Result<SourceCredentialReport.Validation, SourceAccessIssue>?

  var inspectionForValidation: SourceAccessInspection? {
    guard case .success(let inspection) = inspection, inspection.mayValidate,
      validationOperation == nil
    else { return nil }
    if case .failure = validation { return nil }
    return inspection
  }
}
