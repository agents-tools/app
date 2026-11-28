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
    Group {
      if let snapshot = model.snapshot {
        if isEmpty(snapshot) {
          emptyState
        } else {
          Form {
            if hasStatusItems(snapshot) {
              Section("Status") {
                statusItems(snapshot)
              }
            }
            if hasInstalledPackages(snapshot) {
              Section("Installed Packages") {
                installedPackages(snapshot)
              }
            }
          }
          .formStyle(.grouped)
        }
      } else if case .loading = model.loadState {
        ProgressView("Reading installed packages…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView {
          Label("Packages Unavailable", systemImage: "shippingbox")
        } description: {
          Text("Open diagnostics to inspect this scope.")
        } actions: {
          Button("See Configuration Diagnostics") { model.page = .diagnostics }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .toolbar {
      if let snapshot = model.snapshot {
        ToolbarItemGroup(placement: .primaryAction) {
          if !isEmpty(snapshot) {
            Button {
              model.packageScope = model.scope
            } label: {
              Label("Browse Packages…", systemImage: "plus")
            }
            .help("Browse marketplaces and bundles")
            .disabled(!model.canModify)
            .accessibilityIdentifier("packages.browse")
          }
          packageActionsMenu(includeImport: !isEmpty(snapshot))
        }
      }
    }
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

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Packages Installed", systemImage: "shippingbox")
    } description: {
      Text("Packages share skills, instructions, and tools across projects.")
    } actions: {
      Button("Browse Packages…") { model.packageScope = model.scope }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canModify)
        .accessibilityIdentifier("packages.browse")
      Button("Import Configuration…") { model.beginImport() }
        .disabled(!model.canModify)
        .accessibilityIdentifier("packages.import")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func packageActionsMenu(includeImport: Bool) -> some View {
    Menu {
      if includeImport {
        Button("Import Configuration…") { model.beginImport() }
          .disabled(!model.canModify)
          .accessibilityIdentifier("packages.import")
        Divider()
      }
      if model.scope.kind == .project {
        Button("Package Project…") { sheet = .project }
          .disabled(!model.canModify)
          .accessibilityIdentifier("packages.shareProject")
      }
      Button("Create or Publish Bundle…") { sheet = .bundle }
        .disabled(!model.canModify || model.availableComponentSelection.isEmpty)
        .accessibilityIdentifier("packages.authorBundle")
      Button("Export Patches…") { sheet = .patches }
        .accessibilityIdentifier("packages.exportPatches")
      Divider()
      Button("Package Actions…") { sheet = .actions }
        .disabled(model.isTerminating || model.isApplying)
        .accessibilityIdentifier("packages.actions")
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .help("Share, import, and package maintenance")
  }

  @ViewBuilder private func statusItems(_ snapshot: WorkspaceSnapshot) -> some View {
    if snapshot.inspection.recovery.pending {
      HStack(spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
        Text("Pending recovery")
        Spacer()
        Button("Review Pending Recovery") { model.page = .diagnostics }
      }
    }
    if snapshot.inspection.pendingMarketplaceDeployment != nil {
      HStack(spacing: 10) {
        Image(systemName: "clock")
          .foregroundStyle(.secondary)
        Text("Package lock awaiting deployment")
      }
    }
    if let issue = snapshot.inspection.marketplaceIssue {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .padding(.top, 2)
        Text(issue.description)
        Spacer()
        Button("Show Diagnostics") { model.page = .diagnostics }
      }
    }
  }

  @ViewBuilder private func installedPackages(_ snapshot: WorkspaceSnapshot) -> some View {
    if let graph = snapshot.inspection.marketplaceGraph {
      ForEach(graph.roots, id: \.intent.name) { root in
        packageRoot(root, in: graph)
      }
    }
    ForEach(snapshot.inspection.marketplacePackages, id: \.dependency.name) { pin in
      packagePin(pin, in: snapshot)
    }
  }

  private func hasInstalledPackages(_ snapshot: WorkspaceSnapshot) -> Bool {
    snapshot.inspection.marketplaceGraph?.roots.isEmpty == false
      || !snapshot.inspection.marketplacePackages.isEmpty
  }

  private func hasStatusItems(_ snapshot: WorkspaceSnapshot) -> Bool {
    snapshot.inspection.recovery.pending
      || snapshot.inspection.pendingMarketplaceDeployment != nil
      || snapshot.inspection.marketplaceIssue != nil
  }

  private func isEmpty(_ snapshot: WorkspaceSnapshot) -> Bool {
    !hasInstalledPackages(snapshot) && !hasStatusItems(snapshot)
  }

  private func packageRoot(_ root: MarketplaceResolvedRoot, in graph: MarketplaceGraph)
    -> some View
  {
    let node = graph.nodes.first { $0.id == root.node }
    return DetailsGroup(root.intent.name + (node.map { " · " + $0.coordinate.version } ?? "")) {
      LabeledContent("Marketplace") { CompactText(text: root.intent.catalog.location) }
      LabeledContent(
        "Version Requirement", value: DeclarationLabels.requirement(root.intent.requirement))
      if let node {
        ForEach(Array(node.dependencies.enumerated()), id: \.offset) { _, edge in
          let version = graph.nodes.first { $0.id == edge.target }?.coordinate.version
          LabeledContent(
            "Dependency", value: edge.target.package + (version.map { " · " + $0 } ?? ""))
        }
      }
      ForEach(Array(root.intent.selections.enumerated()), id: \.offset) { _, selection in
        LabeledContent(
          selection.package + " / " + selection.member.name,
          value: selection.targets.map(\.displayName).joined(separator: ", "))
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
