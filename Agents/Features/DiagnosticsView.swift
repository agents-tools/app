import SwiftUI

struct DiagnosticsView: View {
  let model: AppModel
  @State private var auditScope: WorkspaceScope?
  @State private var recoveryScope: WorkspaceScope?

  var body: some View {
    Form {
      if model.currentScopeProblems.isEmpty {
        Section {
          currentProblems
        }
      } else {
        Section("Issues") {
          currentProblems
        }
      }

      Section("Checks") {
        LabeledContent("Prompt Audit") {
          Button("Audit…") { auditScope = model.scope }
            .accessibilityIdentifier("diagnostics.audit")
        }
      }

      if !model.diagnostics.isEmpty {
        Section("Reports") { history }
      }
    }
    .formStyle(.grouped)
    .textSelection(.enabled)
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
    let needsRecovery = model.snapshot?.inspection.recovery.pending == true
    if needsRecovery {
      HStack(spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        VStack(alignment: .leading, spacing: 2) {
          Text("Incomplete Operation")
            .font(.headline)
          Text("Recover and recheck this configuration.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Recover…") { recoveryScope = model.scope }
          .buttonStyle(.borderedProminent)
          .disabled(model.isApplying || model.isTerminating)
          .accessibilityIdentifier("diagnostics.recover")
      }
      .padding(.vertical, 2)
    }
    if problems.isEmpty {
      if !needsRecovery {
        switch model.loadState {
        case .loaded:
          HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
              .font(.title3)
              .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
              Text("No Problems Found")
                .font(.headline)
            }
          }
          .padding(.vertical, 2)
        case .loading:
          HStack(spacing: 10) {
            ProgressView()
              .controlSize(.small)
            Text("Reading configuration…")
              .foregroundStyle(.secondary)
          }
        case .existingConfigurationAvailable:
          HStack(spacing: 10) {
            Image(systemName: "doc.badge.plus")
              .foregroundStyle(.secondary)
            Text("Existing configuration available")
            Spacer()
            Button("Review Import…") { model.previewExistingConfiguration() }
              .disabled(!model.canPreviewExistingConfiguration)
          }
        case .idle, .failed:
          HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
              .foregroundStyle(.secondary)
            Text("Configuration not loaded")
            Spacer()
            Button("Read Configuration") { model.refresh() }
          }
        }
      }
    } else {
      ForEach(problems) { diagnostic in DiagnosticRow(diagnostic: diagnostic) }
      if let snapshot = model.snapshot {
        let hasPackages =
          snapshot.inspection.marketplaceIssue != nil
          || snapshot.inspection.pendingMarketplaceDeployment != nil
        let hasChanges = snapshot.inspection.deployments.contains(where: { $0.status != .current })
        let hasDeclaration = snapshot.document?.diagnostics.isEmpty == false
        if hasPackages || hasChanges || hasDeclaration {
          HStack(spacing: 8) {
            if hasPackages {
              Button("Open Packages") { model.page = .packages }
            }
            if hasChanges {
              Button("Review Changes") { model.page = .changes }
            }
            if hasDeclaration {
              Button("Show Declaration") { model.page = .components }
            }
          }
        }
      }
    }
  }

  @ViewBuilder private var history: some View {
    let reports = model.currentDiagnostics
    let otherScopes = model.diagnostics.filter { $0.scope != model.scope }
    if !reports.isEmpty {
      DetailsGroup("This Scope") {
        ForEach(reports) { DiagnosticRow(diagnostic: $0) }
      }
    }
    if !otherScopes.isEmpty {
      DetailsGroup("Other Scopes") {
        ForEach(otherScopes) { DiagnosticRow(diagnostic: $0, showScope: true) }
      }
    }
  }
}

private struct DiagnosticRow: View {
  let diagnostic: AppDiagnostic
  var showScope = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: iconName)
        .foregroundStyle(iconColor)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 3) {
        Text(diagnostic.operation)
          .font(.headline)
        Text(diagnostic.message)
          .font(.callout)
        if let path = diagnostic.path {
          Text(path)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        if showScope {
          Text(diagnostic.scope.title + " · " + diagnostic.scope.root.path)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if diagnostic.blocksTermination {
          Text("This operation reported a cleanup failure.")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private var iconName: String {
    if diagnostic.blocksTermination { return "xmark.octagon.fill" }
    return diagnostic.severity == .information ? "info.circle.fill" : "exclamationmark.triangle.fill"
  }

  private var iconColor: Color {
    if diagnostic.blocksTermination { return .red }
    return diagnostic.severity == .information ? .secondary : .orange
  }
}
