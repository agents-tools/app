import AgentsCore
import AgentsManifest
import AgentsUpdates
import SwiftUI

struct WorkspaceView: View {
  @Bindable var model: AppModel
  @State private var pendingReview: UpdateProposal?
  @State private var packageActionScope: WorkspaceScope?

  var body: some View {
    NavigationSplitView {
      List(
        selection: Binding<WorkspacePage?>(
          get: { model.page },
          set: { page in
            if let page {
              model.page = page
              model.selectedItem = nil
            }
          })
      ) {
        Section("Configuration") {
          Button {
            model.select(.init(kind: .user, root: model.home))
          } label: {
            scopeLabel(.init(kind: .user, root: model.home), symbol: "person.crop.circle")
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("scope.user")
        }
        Section("Projects") {
          ForEach(model.preferences.projects, id: \.self) { url in
            let scope = WorkspaceScope(kind: .project, root: url)
            Button {
              model.select(scope)
            } label: {
              scopeLabel(scope, symbol: "folder")
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Remove from Project List") { model.removeProject(url) }
            }
          }
          Button("Add Project…", systemImage: "plus") { chooseProject(for: model) }
            .accessibilityIdentifier("project.add")
        }
        Section(model.scope.title) {
          ForEach(WorkspacePage.allCases.filter { $0 != .backups }) { page in
            Label(page.title, systemImage: page.symbol)
              .tag(page)
              .accessibilityIdentifier("page.\(page.rawValue)")
          }
        }
        Section("Tools") {
          Label(WorkspacePage.backups.title, systemImage: WorkspacePage.backups.symbol)
            .tag(WorkspacePage.backups)
            .accessibilityIdentifier("page.backups")
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
      .disabled(model.isTerminating || model.isApplying)
    } detail: {
      workspace
        .navigationTitle(model.page.title)
        .navigationSubtitle(model.page == .backups ? "" : model.scope.title)
        .toolbar {
          if model.page != .backups {
            ToolbarItem {
              Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                .disabled(model.isTerminating || model.isApplying)
                .help("Read configuration again")
            }
            ToolbarItem {
              Button("Package Actions…", systemImage: "play.circle") {
                packageActionScope = model.scope
              }.disabled(model.isTerminating || model.isApplying)
            }
            ToolbarItem {
              Button("Inspector", systemImage: "sidebar.right") {
                model.setInspectorVisible(!model.preferences.inspectorVisible)
              }
              .help("Show or hide the inspector")
            }
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { operationStatus }
    }
    .inspector(
      isPresented: Binding(
        get: { model.page != .backups && model.preferences.inspectorVisible },
        set: { if model.page != .backups { model.setInspectorVisible($0) } }
      )
    ) {
      InspectorView(model: model)
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }
    .sheet(
      item: Binding(
        get: { model.manifestDraft == nil ? model.updateSession : nil },
        set: { model.updateSession = $0 })
    ) { _ in UpdateReviewView(model: model) }
    .sheet(item: $model.assistanceSession) { _ in AssistanceView(model: model) }
    .sheet(item: $model.watchStatusSession) { _ in WatchStatusView(model: model) }
    .sheet(item: $model.watchSession) { _ in WatchView(model: model) }
    .sheet(item: $model.importSession) { _ in ImportView(model: model) }
    .sheet(item: $model.connectionSession) { _ in ConnectionView(model: model) }
    .sheet(item: $packageActionScope) { scope in
      PackageActionsSheet(model: model, scope: scope, environment: model.actions.environment(for: scope))
    }
    .sheet(
      item: Binding(
        get: { model.existingConfigurationSession },
        set: { if $0 == nil { model.cancelExistingConfiguration() } })
    ) { _ in ExistingConfigurationView(model: model) }
    .sheet(
      item: $model.registrySession,
      onDismiss: {
        guard let proposal = pendingReview else { return }
        pendingReview = nil
        guard model.scope == proposal.scope else { return }
        model.previewUpdate(proposal)
      }
    ) { session in
      RegistryBrowserSheet(
        inspection: session.inspection, environment: model.actions.environment(for: session.scope)
      ) { addition in
        pendingReview = UpdateProposal(
          id: UUID(), scope: session.scope, title: "Install MCP Server",
          request: addition.updateRequest())
        model.registrySession = nil
      }
    }
    .sheet(
      item: $model.packageScope,
      onDismiss: {
        guard let proposal = pendingReview else { return }
        pendingReview = nil
        model.previewUpdate(proposal)
      }
    ) { scope in
      PackageInstallSheet(
        model: model, scope: scope, environment: model.actions.environment(for: scope)
      ) { proposal in
        pendingReview = proposal
        model.packageScope = nil
      }
    }
    .sheet(item: $model.catalogSession) { _ in SourceCatalogView(model: model) }
    .sheet(item: $model.discoverySession) { _ in DiscoveryView(model: model) }
    .sheet(item: $model.mappingSession) { _ in MappingView(model: model) }
    .sheet(item: $model.manifestDraft) { draft in ManifestDraftView(model: model, fallback: draft) }
    .sheet(item: $model.creationSession) { _ in CreationView(model: model) }
    .sheet(item: $model.promptSession) { _ in PromptPreviewView(model: model) }

  }

  @ViewBuilder private var workspace: some View {
    switch (model.page, model.loadState) {
    case (.backups, _):
      ClientBackupsView(model: model)
    case (.diagnostics, _):
      DiagnosticsView(model: model)
    case (_, .idle):
      ContentUnavailableView {
        Label("Configuration Not Loaded", systemImage: "doc.text.magnifyingglass")
      } actions: {
        Button("Read Configuration") { model.refresh() }
      }
    case (_, .loading):
      VStack(spacing: 12) {
        ProgressView()
        Text("Reading configuration…").foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    case (_, .existingConfigurationAvailable):
      ContentUnavailableView {
        Label("Use Existing Configuration", systemImage: "doc.text")
      } description: {
        Text("Review the changes to your user configuration. Native client files stay as they are.")
      } actions: {
        Button("Preview Configuration…") { model.previewExistingConfiguration() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canPreviewExistingConfiguration)
          .accessibilityIdentifier("existingConfiguration.preview")
      }
    case (_, .failed(let diagnostics)):
      ContentUnavailableView {
        Label("Configuration Unavailable", systemImage: "exclamationmark.triangle")
      } description: {
        Text(diagnostics.map(\.message).joined(separator: "\n")).textSelection(.enabled)
      } actions: {
        Button("Try Again") { model.refresh() }
        Button("Show Diagnostics") { model.page = .diagnostics }
      }
    case (.overview, .loaded(let snapshot)):
      OverviewView(model: model, snapshot: snapshot)
    case (.components, .loaded), (.sources, .loaded):
      DeclarationListView(model: model)
    case (.instructions, .loaded(let snapshot)):
      InstructionsView(model: model, snapshot: snapshot)
    case (.changes, .loaded):
      ChangesView(model: model)
    }
  }

  private func scopeLabel(_ scope: WorkspaceScope, symbol: String) -> some View {
    HStack {
      Label(scope.title, systemImage: symbol).lineLimit(1)
      Spacer(minLength: 4)
      if scope == model.scope {
        Image(systemName: "checkmark").foregroundStyle(.secondary).accessibilityLabel("Selected")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .help(scope.root.path)
  }

  @ViewBuilder private var operationStatus: some View {
    if model.isTerminating {
      Label("Waiting for operations to finish before quitting…", systemImage: "hourglass")
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    } else if model.terminationBlocked {
      Label(
        "Quit paused because cleanup needs attention. See Diagnostics.",
        systemImage: "exclamationmark.triangle"
      )
      .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
    } else if !model.operations.isEmpty {
      HStack {
        ProgressView().controlSize(.small)
        Text(model.operations.values.first?.title ?? "Waiting for operations to finish…")
        Spacer()
      }.padding(8).background(.bar)
    } else if model.page == .overview && model.didApplyExistingConfiguration {
      Label("Existing configuration applied", systemImage: "checkmark.circle")
        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
        .accessibilityIdentifier("existingConfiguration.success")
    }
  }
}

struct OverviewView: View {
  @State private var confirmsRecovery = false
  let model: AppModel
  let snapshot: WorkspaceSnapshot

  var body: some View {
    if snapshot.isEmpty {
      ContentUnavailableView {
        Label("No Configuration", systemImage: "doc.badge.plus")
      } description: {
        Text("This scope has no declaration or resolved state. Browsing leaves it unchanged.")
      } actions: {
        Button("Edit Configuration…") { model.beginDraft(.defaults) }
        Button("New Local Skill…") { model.beginCreation(.skill) }
        if model.scope.kind == .project {
          Button("New Local Instructions…") { model.beginCreation(.instructions) }
        }
        Button("Add from Source…") { model.beginCatalog() }
        Button("Install Package…") { model.packageScope = model.scope }.disabled(!model.canModify)
        Button("Browse MCP Registry…") { model.browseRegistry() }.disabled(!model.canModify)
        Button("Import…") { model.beginImport() }
      }
    } else {
      Form {
        if snapshot.inspection.recovery.pending {
          Section("Recovery Pending") {
            Text(snapshot.inspection.recovery.diagnostic ?? "An earlier operation is incomplete.")
            Button("Recover and Recheck…") { confirmsRecovery = true }.disabled(
              model.isApplying || model.isTerminating)
            Text(
              "Recover the incomplete operation before making further changes."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        Section("Scope") {
          LabeledContent("Location") { PathView(url: snapshot.scope.root, scope: snapshot.scope) }
          LabeledContent(
            "Read", value: snapshot.readAt.formatted(date: .abbreviated, time: .standard))
          LabeledContent(
            "Default agents",
            value: snapshot.effectiveDefaultAgents.isEmpty
              ? "None" : snapshot.effectiveDefaultAgents.map(\.displayName).joined(separator: ", "))
          Text(
            snapshot.document?.declaration.defaultAgents == nil
              ? "Uses built-in defaults."
              : "Default agents are declared in this scope."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Section("Declaration") {
          LabeledContent("Components", value: String(snapshot.components.count))
          LabeledContent("Sources", value: String(snapshot.sources.count))
          LabeledContent("Groups", value: String(snapshot.document?.declaration.groups.count ?? 0))
          LabeledContent(
            "Exports", value: snapshot.document?.declaration.exports.joined(separator: ", ") ?? "")
          Button("View Declaration") { model.page = .components }
          Button("New Local Skill…") { model.beginCreation(.skill) }
          if model.scope.kind == .project {
            Button("New Local Instructions…") { model.beginCreation(.instructions) }
          }
        }
        ManagedStateView(model: model, snapshot: snapshot)
        Section("Read Status") {
          if let inventory = snapshot.inventory {
            LabeledContent("Skill inventory entries", value: String(inventory.count))
          } else {
            Label("Skill inventory unavailable", systemImage: "exclamationmark.triangle")
          }
          LabeledContent(
            "Diagnostics in this session", value: String(model.currentDiagnostics.count))
          Text(
            "Configuration and installed content refresh automatically when files change."
          )
          .foregroundStyle(.secondary)
          Button("Show Diagnostics") { model.page = .diagnostics }
        }
      }
      .formStyle(.grouped)
      .confirmationDialog(
        "Recover this configuration?", isPresented: $confirmsRecovery, titleVisibility: .visible
      ) {
        Button("Recover and Recheck") { model.recoverScope(in: snapshot.scope) }
      } message: {
        Text(
          "Recover the incomplete operation in " + snapshot.scope.root.path
            + ". No new configuration changes will be applied.")
      }
    }
  }
}
