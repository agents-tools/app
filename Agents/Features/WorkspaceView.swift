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
      .disabled(model.isTerminating)
    } detail: {
      workspace
        .navigationTitle(model.page.title)
        .navigationSubtitle(model.scope.title)
        .toolbar {
          ToolbarItem {
            Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
              .disabled(model.isTerminating)
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
        case .changes:
          ContentUnavailableView {
            Label("No Change Review", systemImage: "doc.text.magnifyingglass")
          } description: {
            Text("Configuration previews and applying changes are not available in this build.")
          } actions: {
            Button("About Configuration Changes…") { model.presentedIntent = .reviewChanges }
          }
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
        Text("Waiting for configuration reads to finish…")
        Spacer()
      }.padding(8).background(.bar)
    }
  }
}

struct OverviewView: View {
  let model: AppModel
  let snapshot: WorkspaceSnapshot

  var body: some View {
    if snapshot.isEmpty {
      ContentUnavailableView {
        Label("No Configuration", systemImage: "doc.badge.plus")
      } description: {
        Text("This scope has no declaration or resolved state. Browsing leaves it unchanged.")
      } actions: {
        Button("Configure This Scope…") { model.presentedIntent = .configure }
        Button("Import…") { model.presentedIntent = .importConfiguration }
      }
    } else {
      Form {
        Section("Scope") {
          LabeledContent("Location", value: snapshot.scope.root.path)
          LabeledContent("Manifest", value: snapshot.manifestURL.path)
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
        }
        Section("Read Status") {
          if let inventory = snapshot.inventory {
            LabeledContent("Managed skill deployments", value: String(inventory.count))
          } else {
            Label("Skill inventory unavailable", systemImage: "exclamationmark.triangle")
          }
          LabeledContent(
            "Diagnostics in this session", value: String(model.currentDiagnostics.count))
          Text("Reads are coordinated individually. Refresh after external changes.")
            .foregroundStyle(.secondary)
          Button("Show Diagnostics") { model.page = .diagnostics }
        }
      }
      .formStyle(.grouped)
      .textSelection(.enabled)
    }
  }
}
