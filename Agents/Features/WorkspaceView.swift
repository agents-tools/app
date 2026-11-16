import AgentsCore
import AgentsManifest
import SwiftUI

struct WorkspaceView: View {
  @Bindable var model: AppModel

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
          ForEach(WorkspacePage.allCases) { page in
            Label(page.title, systemImage: page.symbol)
              .tag(page)
              .accessibilityIdentifier("page.\(page.rawValue)")
          }
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
      .disabled(model.isTerminating || model.isApplying)
    } detail: {
      workspace
        .navigationTitle(model.page.title)
        .navigationSubtitle(model.scope.title)
        .toolbar {
          ToolbarItem {
            Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
              .disabled(model.isTerminating || model.isApplying)
              .help("Read configuration again")
          }
          ToolbarItem {
            Button("Inspector", systemImage: "sidebar.right") {
              model.preferences.inspectorVisible.toggle()
            }
            .help("Show or hide the inspector")
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { operationStatus }
    }
    .inspector(isPresented: Bindable(model.preferences).inspectorVisible) {
      InspectorView(model: model)
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }
    .sheet(
      item: Binding(
        get: { model.manifestDraft == nil ? model.updateSession : nil },
        set: { model.updateSession = $0 })
    ) { _ in UpdateReviewView(model: model) }
    .sheet(item: $model.assistanceSession) { _ in AssistanceView(model: model) }
    .sheet(item: $model.discoverySession) { _ in DiscoveryView(model: model) }
    .sheet(item: $model.mappingSession) { _ in MappingView(model: model) }
    .sheet(item: $model.manifestDraft) { draft in ManifestDraftView(model: model, fallback: draft) }
    .sheet(item: $model.creationSession) { _ in CreationView(model: model) }
    .sheet(item: $model.promptSession) { _ in PromptPreviewView(model: model) }
    .sheet(item: $model.presentedIntent) { intent in
      VStack(alignment: .leading, spacing: 16) {
        Text(intent.title).font(.headline)
        Text(intent.unavailableReason).foregroundStyle(.secondary)
        HStack {
          Spacer()
          Button("Done") { model.presentedIntent = nil }.keyboardShortcut(.defaultAction)
        }
      }
      .padding(24)
      .frame(width: 420)
    }
  }

  @ViewBuilder private var workspace: some View {
    if model.page == .diagnostics {
      DiagnosticsView(model: model)
    } else {
      switch model.loadState {
      case .idle:
        ContentUnavailableView {
          Label("Configuration Not Loaded", systemImage: "doc.text.magnifyingglass")
        } actions: {
          Button("Read Configuration") { model.refresh() }
        }
      case .loading:
        VStack(spacing: 12) {
          ProgressView()
          Text("Reading configuration…").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let diagnostics):
        ContentUnavailableView {
          Label("Configuration Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
          Text(diagnostics.map(\.message).joined(separator: "\n")).textSelection(.enabled)
        } actions: {
          Button("Try Again") { model.refresh() }
          Button("Show Diagnostics") { model.page = .diagnostics }
        }
      case .loaded(let snapshot):
        switch model.page {
        case .overview: OverviewView(model: model, snapshot: snapshot)
        case .components, .sources: DeclarationListView(model: model)
        case .instructions: InstructionsView(model: model, snapshot: snapshot)
        case .changes: ChangesView(model: model)
        case .diagnostics: DiagnosticsView(model: model)
        }
      }
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
        Button("Draft Configuration…") { model.beginDraft(.defaults) }
        Button("New Local Skill…") { model.beginCreation(.skill) }
        if model.scope.kind == .project {
          Button("New Local Instructions…") { model.beginCreation(.instructions) }
        }
        Button("Import…") { model.presentedIntent = .importConfiguration }
      }
    } else {
      Form {
        if snapshot.inspection.recovery.pending {
          Section("Recovery Pending") {
            Text(snapshot.inspection.recovery.diagnostic ?? "Core reports an incomplete operation.")
            Button("Recover and Recheck…") { confirmsRecovery = true }.disabled(
              model.isApplying || model.isTerminating)
            Text(
              "Core will attempt its existing recovery under the scope lock. No new changes are applied."
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
            "Declaration and managed state share one read generation. External changes refresh these reads automatically."
          )
          .foregroundStyle(.secondary)
          Button("Show Diagnostics") { model.page = .diagnostics }
        }
      }
      .formStyle(.grouped)
      .textSelection(.enabled)
      .confirmationDialog(
        "Recover this configuration?", isPresented: $confirmsRecovery, titleVisibility: .visible
      ) {
        Button("Recover and Recheck") { model.recoverScope(in: snapshot.scope) }
      } message: {
        Text(
          "Core will attempt recovery for " + snapshot.scope.root.path
            + ". No new configuration changes will be applied.")
      }
    }
  }
}
