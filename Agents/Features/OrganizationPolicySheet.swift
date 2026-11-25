import AgentsCore
import AgentsUpdates
import AppKit
import SwiftUI

struct OrganizationPolicySheet: View {
  let model: AppModel
  let scope: WorkspaceScope
  @Environment(\.dismiss) private var dismiss
  @State private var audit: OrganizationPolicyAudit?
  @State private var failure: String?
  @State private var reading = UUID()

  private var hostControlsScope: Bool {
    let variable =
      scope.kind == .user ? "AGENTS_USER_ORGANIZATION_POLICY" : "AGENTS_PROJECT_ORGANIZATION_POLICY"
    return model.processEnvironment[variable] != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Organization Policy").font(.title2.bold())
      Text(scope.title).foregroundStyle(.secondary)
      Form {
        Section("Policy for This Scope") {
          if hostControlsScope {
            Text("The launch environment selects this policy.")
          } else {
            if let path = model.preferences.organizationPolicyFiles[scope.id] {
              PathView(url: URL(fileURLWithPath: path))
            }
            HStack {
              Button("Choose Policy File…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url { setFile(url) }
              }
              if model.preferences.organizationPolicyFiles[scope.id] != nil {
                Button("Clear Selection") { setFile(nil) }
              }
            }.disabled(model.isApplying || model.isTerminating)
          }
        }
        if let audit {
          Section("Effective Policies") {
            if audit.organization.policies.isEmpty { Text("No organization policy configured.") }
            ForEach(audit.organization.policies.indices, id: \.self) { index in
              let policy = audit.organization.policies[index]
              LabeledContent(
                policy.authority.rawValue.capitalized,
                value: policy.mode?.rawValue ?? policy.outcome.rawValue)
              ForEach(policy.documents, id: \.url) { document in
                Text(document.url.isFileURL ? document.url.path : document.url.absoluteString)
                  .font(.caption).textSelection(.enabled)
              }
            }
          }
          Section("Audit") {
            LabeledContent("Result", value: audit.isBlocked ? "Blocked" : "Passed")
            ForEach(audit.organization.findings.indices, id: \.self) { index in
              let finding = audit.organization.findings[index]
              LabeledContent(finding.rule, value: finding.outcome.rawValue.capitalized)
              Text(finding.identity + " · " + finding.message)
            }
            ForEach(audit.sourceViolations.indices, id: \.self) { index in
              let violation = audit.sourceViolations[index]
              Text(violation.origin.description + " · " + violation.reason.rawValue)
            }
            if let issue = audit.closureIssue { Text(issue) }
          }
        } else if let failure {
          Text(failure).foregroundStyle(.red)
        } else {
          ProgressView("Reading policies…")
        }
      }.formStyle(.grouped)
      HStack {
        Button("Refresh") { reading = UUID() }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(20).frame(minWidth: 520, minHeight: 400)
    .task(id: reading) {
      audit = nil
      failure = nil
      let environment = model.actions.environment(for: scope)
      let installScope = scope.installScope
      let work = Task.detached(priority: .userInitiated) {
        try OrganizationPolicyOperations.audit(scope: installScope, environment: environment)
      }
      do {
        let result = try await withTaskCancellationHandler {
          try await work.value
        } onCancel: {
          work.cancel()
        }
        try Task.checkCancellation()
        audit = result
      } catch {
        if !Task.isCancelled { failure = String(describing: error) }
      }
    }
  }

  private func setFile(_ url: URL?) {
    model.preferences.organizationPolicyFiles[scope.id] = url?.standardizedFileURL.path
    model.refresh()
    reading = UUID()
  }
}
