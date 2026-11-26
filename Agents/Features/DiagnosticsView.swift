import SwiftUI

struct DiagnosticsView: View {
  let model: AppModel
  @State private var auditScope: WorkspaceScope?
  @State private var policyScope: WorkspaceScope?
  @State private var recoveryScope: WorkspaceScope?

  var body: some View {
    List {
      Section("Configuration Problems") {
        currentProblems
      }
      Section("Checks") {
        Button("Organization Policy…") { policyScope = model.scope }
          .accessibilityIdentifier("diagnostics.policy")
        Button("Audit Prompts…") { auditScope = model.scope }
          .accessibilityIdentifier("diagnostics.audit")
      }
      Section("Session History") {
        history
      }
    }
    .listStyle(.inset)
    .buttonStyle(.borderless)
    .textSelection(.enabled)
    .sheet(item: $policyScope) { scope in
      OrganizationPolicySheet(model: model, scope: scope)
    }
    .sheet(item: $auditScope) { scope in
      PromptAuditSheet(scope: scope, environment: model.actions.environment(for: scope))
    }
    .confirmationDialog(
      "Recover this configuration?",
      isPresented: Binding(
        get: { recoveryScope != nil }, set: { if !$0 { recoveryScope = nil } }),
      titleVisibility: .visible, presenting: recoveryScope
    ) { scope in
      Button("Recover and Recheck") { model.recoverScope(in: scope) }
    } message: { scope in
      Text("Recover the incomplete operation in " + scope.root.path + ".")
    }
  }

  @ViewBuilder private var currentProblems: some View {
    let problems = model.currentScopeProblems
    if model.snapshot?.inspection.recovery.pending == true {
      Button("Recover and Recheck…") { recoveryScope = model.scope }
        .disabled(model.isApplying || model.isTerminating)
        .accessibilityIdentifier("diagnostics.recover")
    }
    if problems.isEmpty {
      switch model.loadState {
      case .loaded:
        Label("No problems reported in this configuration", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      case .loading:
        ProgressView("Reading configuration…")
      case .existingConfigurationAvailable:
        Button("Review Existing Configuration Import…") { model.previewExistingConfiguration() }
          .disabled(!model.canPreviewExistingConfiguration)
      case .idle, .failed:
        Button("Read Configuration") { model.refresh() }
      }
    } else {
      ForEach(problems) { diagnostic in DiagnosticRow(diagnostic: diagnostic) }
      if let snapshot = model.snapshot {
        if snapshot.inspection.marketplaceIssue != nil
          || snapshot.inspection.pendingMarketplaceDeployment != nil
        {
          Button("Open Packages") { model.page = .packages }
        }
        if snapshot.inspection.deployments.contains(where: { $0.status != .current }) {
          Button("Review Changes") { model.page = .changes }
        }
        if snapshot.document?.diagnostics.isEmpty == false {
          Button("Show Declaration") { model.page = .components }
        }
      }
    }
  }

  @ViewBuilder private var history: some View {
    let records = model.updateRecords.filter { $0.scope == model.scope }
    let reports = model.currentDiagnostics
    let otherScopes = model.diagnostics.filter { $0.scope != model.scope }
    if records.isEmpty, reports.isEmpty, otherScopes.isEmpty {
      Text("No operations or reports in this session.").foregroundStyle(.secondary)
    }
    if !records.isEmpty {
      DetailsGroup("Operations in This Scope") {
        ForEach(records.reversed()) { record in
          LabeledContent(record.title, value: record.terminal.message)
        }
      }
    }
    if !reports.isEmpty {
      DetailsGroup("All Reports for This Scope") {
        ForEach(reports) { diagnostic in DiagnosticRow(diagnostic: diagnostic) }
      }
    }
    if !otherScopes.isEmpty {
      DetailsGroup("Reports from Other Scopes") {
        ForEach(otherScopes) { diagnostic in DiagnosticRow(diagnostic: diagnostic) }
      }
    }
  }
}

private struct DiagnosticRow: View {
  let diagnostic: AppDiagnostic

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(
        diagnostic.operation,
        systemImage: diagnostic.severity == .information ? "info.circle" : "exclamationmark.triangle"
      )
      .font(.headline)
      Text(diagnostic.message)
      Text(diagnostic.scope.title + " · " + diagnostic.scope.root.path)
        .font(.caption).foregroundStyle(.secondary)
      if let path = diagnostic.path { Text(path).font(.caption).foregroundStyle(.secondary) }
      if diagnostic.blocksTermination {
        Text("This operation reported a cleanup failure.").foregroundStyle(.red)
      }
    }
    .padding(.vertical, 4)
  }
}
