import AgentsCore
import AgentsUpdates
import SwiftUI

struct PackagesView: View {
  let model: AppModel

  @State private var sheet: Sheet?

  private enum Sheet: String, Identifiable {
    case actions, bundle, project, patches

    var id: Self { self }
  }

  var body: some View {
    List {
      Section("Discovery") {
        Button("Browse Marketplaces and Bundles…") { model.packageScope = model.scope }
          .disabled(!model.canModify)
          .accessibilityIdentifier("packages.browse")
      }

      Section("Installed Packages") {
        if let snapshot = model.snapshot {
          installedPackages(snapshot)
        } else if case .loading = model.loadState {
          ProgressView("Reading installed packages…")
        } else {
          Button("See Configuration Diagnostics") { model.page = .diagnostics }
        }
        Button("Manage Packages…") { model.packageScope = model.scope }
          .disabled(!model.canModify)
          .accessibilityIdentifier("packages.manage")
      }

      Section("Share and Import") {
        if model.scope.kind == .project {
          Button("Package Project…") { sheet = .project }
            .disabled(!model.canModify)
            .accessibilityIdentifier("packages.shareProject")
        }
        Button("Create or Publish Bundle…") { sheet = .bundle }
          .disabled(!model.canModify || model.availableComponentSelection.isEmpty)
          .accessibilityIdentifier("packages.authorBundle")
        Button("Import Configuration…") { model.beginImport() }
          .disabled(!model.canModify)
          .accessibilityIdentifier("packages.import")
        Button("Export Patches…") { sheet = .patches }
          .accessibilityIdentifier("packages.exportPatches")
      }

      Section("Package Maintenance") {
        Button("Package Actions…") { sheet = .actions }
          .disabled(model.isTerminating || model.isApplying)
          .accessibilityIdentifier("packages.actions")
      }
    }
    .listStyle(.inset)
    .buttonStyle(.borderless)
    .sheet(item: $sheet) { sheet in
      let scope = model.scope
      let environment = model.actions.environment(for: scope)
      switch sheet {
      case .actions:
        PackageActionsSheet(model: model, scope: scope, environment: environment)
      case .bundle:
        if let snapshot = model.snapshot {
          BundleAuthoringSheet(snapshot: snapshot, environment: environment)
        }
      case .project:
        if let snapshot = model.snapshot {
          ProjectPackageSheet(snapshot: snapshot, environment: environment)
        }
      case .patches:
        ProducerPatchSheet(scope: scope.installScope, environment: environment)
      }
    }
  }

  @ViewBuilder private func installedPackages(_ snapshot: WorkspaceSnapshot) -> some View {
    if snapshot.inspection.pendingMarketplaceDeployment != nil {
      Label("Package lock awaiting deployment", systemImage: "clock")
    }
    if let issue = snapshot.inspection.marketplaceIssue {
      Label(issue.description, systemImage: "exclamationmark.triangle")
      Button("Show Diagnostics") { model.page = .diagnostics }
    }
    if let graph = snapshot.inspection.marketplaceGraph {
      ForEach(graph.roots, id: \.intent.name) { root in
        packageRoot(root, in: graph)
      }
    }
    ForEach(snapshot.inspection.marketplacePackages, id: \.dependency.name) { pin in
      packagePin(pin, in: snapshot)
    }
    if snapshot.inspection.marketplaceGraph?.roots.isEmpty != false,
      snapshot.inspection.marketplacePackages.isEmpty,
      snapshot.inspection.pendingMarketplaceDeployment == nil,
      snapshot.inspection.marketplaceIssue == nil
    {
      if snapshot.inspection.recovery.pending {
        Button("Review Pending Recovery") { model.page = .diagnostics }
      } else {
        Text("No packages installed in this scope.").foregroundStyle(.secondary)
      }
    }
  }

  private func packageRoot(_ root: MarketplaceResolvedRoot, in graph: MarketplaceGraph)
    -> some View
  {
    let node = graph.nodes.first { $0.id == root.node }
    return DetailsGroup(root.intent.name + (node.map { " · " + $0.coordinate.version } ?? "")) {
      LabeledContent("Marketplace") { CompactText(text: root.intent.catalog.location) }
      LabeledContent("Version Requirement", value: DeclarationLabels.requirement(root.intent.requirement))
      if let node {
        ForEach(Array(node.dependencies.enumerated()), id: \.offset) { _, edge in
          let version = graph.nodes.first { $0.id == edge.target }?.coordinate.version
          LabeledContent("Dependency", value: edge.target.package + (version.map { " · " + $0 } ?? ""))
        }
      }
      ForEach(Array(root.intent.selections.enumerated()), id: \.offset) { _, selection in
        HStack {
          Text(selection.package + " / " + selection.member.name)
          Spacer()
          Text(selection.targets.map(\.displayName).joined(separator: ", "))
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func packagePin(_ pin: MarketplacePin, in snapshot: WorkspaceSnapshot) -> some View {
    DetailsGroup(pin.dependency.name + " · " + pin.dependency.coordinate.version) {
      LabeledContent("Marketplace") { CompactText(text: pin.dependency.catalog.location) }
      let records = Set(pin.componentRecords)
      ForEach(snapshot.inspection.components.filter { records.contains($0.record) }, id: \.record) {
        component in
        LabeledContent(
          component.name, value: component.recipients.map(\.displayName).joined(separator: ", "))
      }
    }
  }
}
