import AgentsCore
import SwiftUI

struct SourceAccessSection: View {
  let model: AppModel
  let selection: SourceAccessSelection

  var body: some View {
    Section("Source Access") {
      if let session = model.sourceAccessSession, session.selection == selection.id,
        let inspection = session.inspection
      {
        switch inspection {
        case .success(let inspection):
          reportRows(inspection.report)
          validationRows(session, inspection: inspection)
        case .failure(let issue):
          Label(issue.message, systemImage: "exclamationmark.circle")
        }
      } else {
        ProgressView("Inspecting source access…").controlSize(.small)
      }
    }
  }

  @ViewBuilder
  private func reportRows(_ report: SourceCredentialReport) -> some View {
    LabeledContent("Provider", value: providerName(report.provider))
    LabeledContent("Transport", value: transportName(report.transport))
    LabeledContent("Effective Host", value: report.effectiveHost ?? "—")
    LabeledContent("Credential Category", value: categoryName(report.credentialSource))
    LabeledContent("Credential Availability", value: availabilityName(report.availability))
  }

  @ViewBuilder
  private func validationRows(_ session: SourceAccessSession, inspection: SourceAccessInspection)
    -> some View
  {
    let enabled =
      session.inspectionForValidation != nil
      && !model.isSourceAccessValidationOutstanding
    Button("Validate Source") { model.validateSourceAccess(selection) }
      .onKeyPress(.return) {
        guard enabled else { return .ignored }
        model.validateSourceAccess(selection)
        return .handled
      }
      .disabled(!enabled)
      .help("Ask the provider to verify the configured credential.")
    if !inspection.mayValidate {
      LabeledContent("Validation", value: "Unsupported")
    } else if session.validationOperation != nil {
      ProgressView("Validating…").controlSize(.small)
      Button("Cancel Validation") { model.cancelSourceAccessValidation(selection.id) }
        .keyboardShortcut(.cancelAction)
    } else if let validation = session.validation {
      switch validation {
      case .success(.accepted):
        LabeledContent("Validation", value: "Accepted")
        Text("The provider accepted the configured credential.").foregroundStyle(.secondary)
      case .success(.refused):
        LabeledContent("Validation", value: "Refused")
        Text("The provider refused the configured credential.").foregroundStyle(.secondary)
      case .success(.indeterminate):
        LabeledContent("Validation", value: "Inconclusive")
        Text("Core could not verify the configured credential.").foregroundStyle(.secondary)
      case .failure(let issue):
        LabeledContent("Validation", value: "Inconclusive")
        Text(issue.message).foregroundStyle(.secondary)
      }
    } else {
      LabeledContent("Validation", value: "Not Validated")
      if model.isSourceAccessValidationOutstanding {
        Text("Waiting for the previous check to finish.").foregroundStyle(.secondary)
      }
    }
  }
}

private func providerName(_ provider: SourceProvider?) -> String {
  switch provider {
  case .github: "GitHub"
  case .gitlab: "GitLab"
  case nil: "—"
  }
}

private func transportName(_ transport: SourceCredentialReport.Transport) -> String {
  switch transport {
  case .local: "Local"
  case .git: "Git"
  case .http: "HTTP"
  case .https: "HTTPS"
  case .ssh: "SSH"
  case .archive: "Archive Mirror"
  }
}

private func categoryName(_ category: SourceCredentialBinding.Category?) -> String {
  switch category {
  case .supplied: "Supplied"
  case .environment: "Environment"
  case .opaque: "Opaque"
  case nil: "None"
  }
}

private func availabilityName(_ availability: SourceCredentialReport.Availability) -> String {
  switch availability {
  case .available: "Available"
  case .unavailable: "Unavailable"
  case .unconfigured: "Not Configured"
  case .delegatedUnverified: "Delegated / Unverified"
  case .sshManaged: "SSH-Managed"
  }
}

extension SourceAccessIssue {
  fileprivate var message: String {
    switch self {
    case .inputsChanged: "Source access changed. Refresh to inspect it again."
    case .policyUnreadable: "The effective source policy could not be read."
    case .policyDenied: "The effective source policy blocks this route."
    case .access(let error): error.errorDescription ?? "Source access could not be inspected."
    case .settings(let error): error.localizedDescription
    case .unsupportedAlias: "Source access requires an alias without surrounding whitespace."
    case .unavailable: "Source access could not be determined. Refresh to inspect it again."
    }
  }
}
