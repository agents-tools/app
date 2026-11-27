import AgentsCore
import AgentsManifest
import AgentsUpdates
import AppKit
import SwiftUI

struct WorkspaceView: View {
  @Bindable var model: AppModel
  private enum Panel: String, Identifiable {
    case clients, access, cache
    var id: Self { self }
    var title: String {
      switch self {
      case .clients: "Clients on This Mac"
      case .access: "User Source Access"
      case .cache: "Source Cache"
      }
    }
  }

  @State private var panel: Panel?
  @State private var pendingReview: UpdateProposal?

  var body: some View {
    NavigationSplitView {
      List(
        selection: Binding<WorkspacePage?>(
          get: { model.page },
          set: { if let page = $0 { model.page = page } })
      ) {
        Section("Scope") {
          scopePicker
        }
        Section("Configuration") {
          ForEach(WorkspacePage.allCases.filter(\.showsClientFilter)) { page in pageRow(page) }
        }
        Section("Distribution & Maintenance") {
          ForEach(
            [WorkspacePage.packages, .sources, .installedComponents, .backups]
          ) { page in pageRow(page) }
          if model.page == .diagnostics { pageRow(.diagnostics) }
        }
        if model.page == .components {
          Section("Advanced") { pageRow(.components) }
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
      .disabled(model.isTerminating || model.isApplying)
    } detail: {
      workspaceWithSubtitle
        .navigationTitle(model.page.title)
        .toolbar {
          if model.page.showsClientFilter, model.snapshot != nil {
            ToolbarItem {
              ClientFilterPicker(selection: $model.clientFilter)
                .accessibilityIdentifier("workspace.clientFilter")
            }
          }
          if model.page == .overview {
            ToolbarItem {
              Button("Detect Clients…", systemImage: "desktopcomputer") {
                model.redetectClients()
                panel = .clients
              }
              .accessibilityIdentifier("overview.detectClients")
            }
          }
          if model.page == .sources {
            ToolbarItem {
              Menu("Source Options", systemImage: "slider.horizontal.3") {
                Button("User Source Access…") { panel = .access }
                Button("Source Cache…") { panel = .cache }
              }
              .accessibilityIdentifier("sources.options")
            }
          }
          if model.page != .backups {
            ToolbarItem {
              Button("Refresh", systemImage: "arrow.clockwise") { model.refresh() }
                .disabled(model.isTerminating || model.isApplying)
                .help("Read configuration again")
            }
          }
          if model.page.hasInspector, model.snapshot != nil {
            ToolbarItem {
              Button("Inspector", systemImage: "sidebar.right") {
                model.setInspectorVisible(!model.preferences.inspectorVisible)
              }
              .help("Show or hide the inspector")
              .accessibilityIdentifier("workspace.toggleInspector")
            }
          }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { operationStatus }
    }
    .inspector(
      isPresented: Binding(
        get: { model.page.hasInspector && model.snapshot != nil && model.preferences.inspectorVisible },
        set: { if model.page.hasInspector, model.snapshot != nil { model.setInspectorVisible($0) } }
      )
    ) {
      inspector.inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }
    .sheet(
      item: Binding(
        get: { model.manifestDraft == nil ? model.updateSession : nil },
        set: { model.updateSession = $0 })
    ) { _ in UpdateReviewView(model: model) }
    .sheet(item: $panel) { selection in
      VStack(spacing: 0) {
        HStack {
          Text(selection.title).font(.headline)
          Spacer()
          Button("Done") { panel = nil }.keyboardShortcut(.cancelAction)
        }
        .padding()
        Divider()
        switch selection {
        case .clients: ClientSettingsView(model: model)
        case .access: SourceAccessSettingsView(model: model)
        case .cache: AcquisitionCacheSettingsView(environment: model.actions.environment(for: model.scope))
        }
      }
      .frame(minWidth: 540, idealWidth: 620, minHeight: 440, idealHeight: 550)
    }
    .sheet(item: $model.assistanceSession) { _ in AssistanceView(model: model) }
    .sheet(item: $model.watchStatusSession) { _ in WatchStatusView(model: model) }
    .sheet(item: $model.watchSession) { _ in WatchView(model: model) }
    .sheet(item: $model.importSession) { _ in ImportView(model: model) }
    .sheet(item: $model.connectionSession) { _ in ConnectionView(model: model) }
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

  @ViewBuilder private var workspaceWithSubtitle: some View {
    if model.page == .skills, case .loaded = model.loadState {
      workspace
    } else {
      workspace.navigationSubtitle(model.page == .backups ? "" : model.scope.title)
    }
  }

  @ViewBuilder private var workspace: some View {
    switch (model.page, model.loadState) {
    case (.backups, _):
      ClientBackupsView(model: model)
    case (.diagnostics, _):
      DiagnosticsView(model: model).id(model.scope.id)
    case (.packages, _):
      PackagesView(model: model).id(model.scope.id)
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
        Label("Import User Configuration", systemImage: "doc.text")
      } description: {
        Text("Import your sources, skills, and instructions from agents.json.")
      } actions: {
        Button("Review Import…") { model.previewExistingConfiguration() }
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
      OverviewView(model: model, snapshot: snapshot).id(snapshot.scope.id)
    case (.skills, .loaded(let snapshot)):
      SkillWorkspaceView(model: model, snapshot: snapshot)
        .safeAreaInset(edge: .bottom) {
          if let client = model.clientFilter,
            !snapshot.skillWorkspaceItems.isEmpty,
            !snapshot.skillWorkspaceItems.contains(where: { $0.isUsed(by: client, in: snapshot.scope) })
          {
            HStack {
              Text("No skills match \(client.displayName).")
              Button("Show All Clients") { model.clientFilter = nil }
                .accessibilityIdentifier("skills.showAllClients")
            }
            .padding(8).frame(maxWidth: .infinity).background(.bar)
          }
        }
        .id(snapshot.scope.id)
    case (.components, .loaded), (.sources, .loaded):
      DeclarationListView(model: model).id(model.scope.id)
    case (.instructions, .loaded(let snapshot)):
      InstructionsView(model: model, snapshot: snapshot).id(snapshot.scope.id)
    case (.mcp, .loaded(let snapshot)):
      NativeCapabilityView(model: model, snapshot: snapshot, kind: .mcpServer)
        .id(snapshot.scope.id)
    case (.other, .loaded(let snapshot)):
      NativeCapabilityView(model: model, snapshot: snapshot, kind: nil).id(snapshot.scope.id)
    case (.installedComponents, .loaded):
      InstalledComponentsView(model: model)
    }
  }

  @ViewBuilder private var inspector: some View {
    if model.page == .skills, let snapshot = model.snapshot {
      SkillWorkspaceInspector(model: model, snapshot: snapshot)
        .id(snapshot.scope.id)
        .accessibilityIdentifier("workspace.inspector")
    } else if model.page.hasInspector {
      InspectorView(model: model)
    }
  }

  private var scopePicker: some View {
    HStack(spacing: 6) {
      Picker("Scope", selection: Binding(get: { model.scope }, set: model.select)) {
        ForEach(model.scopes) { scope in
          Label(scopePickerTitle(scope), systemImage: scope.kind == .user ? "person.crop.circle" : "folder")
            .help(scope.root.path)
            .tag(scope)
            .accessibilityIdentifier("scope.\(scope.kind == .user ? "user" : scope.id)")
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .accessibilityIdentifier("workspace.scope")
      .help(model.scope.root.path)
      Menu("Scope Actions", systemImage: "ellipsis.circle") {
        Button("Add Project…", systemImage: "plus") { chooseProject(for: model) }
          .accessibilityIdentifier("project.add")
        if model.scope.kind == .project {
          Button("Remove from Project List") { model.removeProject(model.scope.root) }
        }
        Divider()
        Button("Configure Default Clients…") { model.beginDraft(.defaults) }.disabled(!model.canModify)
        Button("Show Declaration") { model.page = .components }
          .disabled(model.snapshot == nil)
          .accessibilityIdentifier("workspace.declaration")
        if case .existingConfigurationAvailable = model.loadState {
          Button("Review Existing Configuration Import…") { model.previewExistingConfiguration() }
            .disabled(!model.canPreviewExistingConfiguration)
        }
        Button("Reveal Scope in Finder") {
          NSWorkspace.shared.open(model.scope.root)
        }
        Button("Copy Scope Path") { copyText(model.scope.root.path) }
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .labelStyle(.iconOnly)
      .fixedSize()
      .help("Scope actions")
      .accessibilityIdentifier("workspace.scopeActions")
    }
    .padding(.vertical, 2)
  }

  private func scopePickerTitle(_ scope: WorkspaceScope) -> String {
    if scope.kind == .project, model.scopes.contains(where: { $0 != scope && $0.title == scope.title }) {
      return scope.root.path
    }
    return scope.title
  }

  private func pageRow(_ page: WorkspacePage) -> some View {
    Label(page.title, systemImage: page.symbol)
      .tag(page)
      .accessibilityIdentifier("page.\(page.rawValue)")
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
    } else if model.page == .overview && model.didApplyExistingConfiguration {
      Label("Configuration imported", systemImage: "checkmark.circle")
        .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
        .accessibilityIdentifier("existingConfiguration.success")
    }
  }
}

struct OverviewView: View {
  let model: AppModel
  let snapshot: WorkspaceSnapshot

  @State private var showingManagedState = false

  var body: some View {
    Group {
      if showingManagedState, model.clientFilter == nil {
        managedState
      } else {
        summary
      }
    }
    .onChange(of: model.clientFilter) { showingManagedState = false }
  }

  private var summary: some View {
    let counts = OverviewCounts(snapshot: snapshot, client: model.clientFilter)
    let problems = model.currentScopeProblems
    return Form {
      if snapshot.isEmpty, snapshot.skillWorkspaceItems.isEmpty,
        snapshot.inspection.components.isEmpty
      {
        Section("Get Started") {
          actionRow("Configure Default Clients…", symbol: "slider.horizontal.3") {
            model.beginDraft(.defaults)
          }
          .disabled(!model.canModify)
          actionRow("Create a Local Skill…", symbol: "plus.circle") {
            model.beginCreation(.skill)
          }
          .disabled(!model.canModify)
          actionRow("Add from Source…", symbol: "square.and.arrow.down") {
            model.beginCatalog()
          }
          .disabled(!model.canModify)
          actionRow("Import Configuration…", symbol: "tray.and.arrow.down") {
            model.beginImport()
          }
          .disabled(!model.canModify)
        }
      }

      Section {
        categoryLink(.skills, count: counts.skills, subtitle: skillBreakdown(counts))
        categoryLink(.instructions, count: counts.instructions)
        categoryLink(.mcp, count: counts.mcp)
        categoryLink(.other, count: counts.other)
      } header: {
        if let client = model.clientFilter {
          HStack(alignment: .firstTextBaseline) {
            Text("\(client.displayName) Configuration")
            Spacer()
            Button("Show All Clients") { model.clientFilter = nil }
              .buttonStyle(.link)
              .controlSize(.small)
              .accessibilityIdentifier("overview.showAllClients")
          }
        } else {
          Text("Configuration")
        }
      }

      if model.clientFilter == nil {
        Section("Clients") {
          ForEach(AgentID.allCases, id: \.self) { client in
            clientLink(client, counts: OverviewCounts(snapshot: snapshot, client: client))
          }
        }
      }

      Section("Scope Issues") {
        Button {
          model.refresh()
          model.page = .diagnostics
        } label: {
          navigationRowLabel(
            problems.isEmpty ? "Check Configuration…" : "Review Configuration Problems",
            symbol: problems.isEmpty ? "checkmark.circle" : "exclamationmark.triangle",
            symbolColor: problems.isEmpty ? .green : .orange,
            count: problems.isEmpty ? nil : problems.count)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityIdentifier("overview.diagnostics")
      }

      Section {
        Toggle(
          "On-Device Assistance",
          isOn: Binding(
            get: { model.preferences.assistanceEnabled },
            set: { model.setAssistanceEnabled($0) }))
          .help("Explain skills and configuration changes with an on-device model.")
      } header: {
        Text("On This Mac")
      } footer: {
        if model.preferences.assistanceEnabled {
          Text(AssistanceAvailability.status)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Section("Scope Details") {
        DetailsGroup("Configuration Files and Defaults") {
          LabeledContent("Location") { PathView(url: snapshot.scope.root, scope: snapshot.scope) }
          LabeledContent("Declaration") {
            PathView(url: snapshot.manifestURL, scope: snapshot.scope)
          }
          LabeledContent("Resolved State") {
            PathView(url: snapshot.resolvedURL, scope: snapshot.scope)
          }
          LabeledContent("Subscriptions") {
            PathView(url: snapshot.watchURL, scope: snapshot.scope)
          }
          LabeledContent("Read") {
            Text(snapshot.readAt.formatted(date: .abbreviated, time: .standard))
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          LabeledContent(
            "Default Agents",
            value: snapshot.effectiveDefaultAgents.isEmpty
              ? "None" : snapshot.effectiveDefaultAgents.map(\.displayName).joined(separator: ", "))
          Button {
            model.page = .components
          } label: {
            navigationRowLabel("Show Declaration")
          }
          .buttonStyle(RowButtonStyle())
        }
        if model.clientFilter == nil, !snapshot.isEmpty || !snapshot.inspection.deployments.isEmpty
          || !snapshot.inspection.resources.isEmpty
        {
          Button {
            showingManagedState = true
          } label: {
            navigationRowLabel("Show Installation Records")
          }
          .buttonStyle(RowButtonStyle())
          .accessibilityIdentifier("overview.managedState")
        }
      }
    }
    .formStyle(.grouped)
  }

  private var managedState: some View {
    VStack(spacing: 0) {
      HStack {
        Button("Back to Overview", systemImage: "chevron.backward") { showingManagedState = false }
          .buttonStyle(.borderless)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("overview.backFromManagedState")
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.bar)
      Divider()
      ManagedStateView(model: model, snapshot: snapshot)
    }
  }

  private func skillBreakdown(_ counts: OverviewCounts) -> String? {
    guard snapshot.scope.kind == .project, counts.userSkills > 0 else { return nil }
    return "\(counts.skills - counts.userSkills) project · \(counts.userSkills) user"
  }

  private func actionRow(
    _ title: String,
    symbol: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.body)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(Color.accentColor)
          .frame(width: 20, alignment: .center)
          .accessibilityHidden(true)
        Text(title)
        Spacer(minLength: 12)
      }
      .padding(.vertical, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(RowButtonStyle())
  }

  private func categoryLink(_ page: WorkspacePage, count: Int, subtitle: String? = nil) -> some View {
    Button {
      model.page = page
    } label: {
      navigationRowLabel(
        page.title,
        symbol: page.symbol,
        symbolColor: .accentColor,
        subtitle: subtitle,
        count: count)
    }
    .buttonStyle(RowButtonStyle())
    .accessibilityIdentifier("overview.category.\(page.rawValue)")
  }

  private func clientLink(_ client: AgentID, counts: OverviewCounts) -> some View {
    Button {
      model.showClientOverview(client)
    } label: {
      navigationRowLabel(
        client.displayName,
        symbol: "terminal",
        symbolColor: .secondary,
        count: counts.total)
    }
    .buttonStyle(RowButtonStyle())
    .help("View \(client.displayName) configuration in this scope")
    .accessibilityIdentifier("overview.client.\(client.rawValue)")
  }

  private func navigationRowLabel(
    _ title: String,
    symbol: String? = nil,
    symbolColor: Color = .secondary,
    subtitle: String? = nil,
    count: Int? = nil
  ) -> some View {
    HStack(spacing: 10) {
      if let symbol {
        Image(systemName: symbol)
          .font(.body)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(symbolColor)
          .frame(width: 20, alignment: .center)
          .accessibilityHidden(true)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 12)
      if let count {
        Text(count, format: .number)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      Image(systemName: "chevron.forward")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .padding(.vertical, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      RowBody(configuration: configuration)
    }

    private struct RowBody: View {
      @Environment(\.isEnabled) private var isEnabled
      let configuration: Configuration

      var body: some View {
        configuration.label
          .opacity(isEnabled ? (configuration.isPressed ? 0.55 : 1) : 0.45)
      }
    }
  }
}

private struct OverviewCounts {
  let skills: Int
  let userSkills: Int
  var instructions = 0
  var mcp = 0
  var other = 0

  var total: Int { skills + instructions + mcp + other }

  init(snapshot: WorkspaceSnapshot, client: AgentID?) {
    let skills = snapshot.skillWorkspaceItems.filter { item in
      client.map { item.isUsed(by: $0, in: snapshot.scope) } ?? true
    }
    self.skills = skills.count
    userSkills = skills.count { $0.scope.kind == .user }

    for component in snapshot.inspection.components {
      if let client, !component.recipients.contains(client) { continue }
      switch component.kind {
      case .skills: break
      case .instructions: instructions += 1
      case .mcpServer: mcp += 1
      default: other += 1
      }
    }
  }
}
