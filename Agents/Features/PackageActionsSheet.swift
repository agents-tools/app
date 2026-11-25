import AgentsCore
import AgentsManifest
import AgentsUpdates
import SwiftUI

struct PackageActionsSheet: View {
  let model: AppModel
  let scope: WorkspaceScope
  let environment: RuntimeEnvironment

  private enum Page: String, CaseIterable {
    case actions = "Actions"
    case simulation = "Simulate"
    case access = "Project Access"
  }

  private struct SimulationRequest: Hashable {
    let event: LifecycleEvent
    let revision: UUID
  }

  @Environment(\.dismiss) private var dismiss
  @State private var page = Page.actions
  @State private var listing: LifecycleInspection?
  @State private var trust: Result<[LifecycleTrustRecord], any Error>?
  @State private var validation: [LifecycleDiagnostic]?
  @State private var validating = false
  @State private var showFindings = false
  @State private var reload = UUID()
  @State private var source: LifecycleAuthority?
  @State private var eventFilter: LifecycleEvent?
  @State private var selection: LifecycleActionSummary.Selection?
  @State private var event = LifecycleEvent.postInstall
  @State private var simulation: LifecycleTestReview?
  @State private var simulatedEvent: LifecycleEvent?
  @State private var simulationRevision = UUID()
  @State private var confirmTest = false
  @State private var results: [LifecycleActionResult] = []
  @State private var configuration: PackageActionConfigurationSheet.Mode?
  @State private var working = false
  @State private var notice: String?
  @State private var messages: [AppDiagnostic] = []

  private var document: DeclarationDocument? {
    model.snapshot?.scope == scope ? model.snapshot?.document : nil
  }

  private var canTest: Bool {
    !model.isApplying && !model.isTerminating && model.snapshot?.inspection.recovery.pending != true
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Package Actions").font(.headline)
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
          .labelStyle(.iconOnly).help("Read package actions again")
          .disabled(working || validating)
      }
      LabeledContent("Scope") { PathView(url: scope.root, scope: scope) }
      Picker("View", selection: $page) {
        ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Package action view")
        .disabled(working)
      switch page {
      case .actions: actions
      case .simulation: simulationPane
      case .access: access
      }
      if let notice {
        Text(notice).foregroundStyle(.secondary)
      }
      ForEach(messages) { diagnostic in
        Text(verbatim: diagnostic.message).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        if working { ProgressView().controlSize(.small) }
        Spacer()
        Button(working ? "Stop" : "Done") {
          if working { model.cancelQueuedOperations() } else { dismiss() }
        }.keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(minWidth: 660, minHeight: 520)
    .interactiveDismissDisabled(working || model.isApplying)
    .onChange(of: model.scope) { _, current in
      if current != scope { dismiss() }
    }
    .task(id: reload) {
      let (inspection, records) = await Task.detached { [scope, environment] in
        (
          LifecycleOperations.list(scope: scope.installScope, environment: environment),
          Result { try LifecycleOperations.storedTrust(environment: environment) }
        )
      }.value
      guard !Task.isCancelled else { return }
      listing = inspection
      trust = records
      if let selection, !inspection.actions.contains(where: { $0.selection == selection }) {
        self.selection = nil
      }
    }
    .sheet(item: $configuration) { mode in
      PackageActionConfigurationSheet(
        model: model, scope: scope, environment: environment, mode: mode
      ) { message in
        configuration = nil
        notice = message
        refresh()
      }
    }
  }

  @ViewBuilder private var actions: some View {
    if let listing {
      let filtered = listing.actions.filter {
        (source == nil || $0.source.authority == source)
          && (eventFilter == nil || $0.event == eventFilter)
      }
      HStack {
        Picker("Source", selection: $source) {
          Text("All Sources").tag(nil as LifecycleAuthority?)
          Text("Administrator").tag(Optional(LifecycleAuthority.administrator))
          Text("User").tag(Optional(LifecycleAuthority.user))
          if scope.kind == .project { Text("Project").tag(Optional(LifecycleAuthority.project)) }
        }.pickerStyle(.menu)
        Picker("Event", selection: $eventFilter) {
          Text("All Events").tag(nil as LifecycleEvent?)
          ForEach(LifecycleEvent.allCases, id: \.self) { event in
            Text(event.actionTitle).tag(Optional(event))
          }
        }.pickerStyle(.menu)
        Spacer()
        Button("Validate") { validate() }.disabled(validating || working)
        if let document {
          if document.declaration.lifecycle == nil {
            Button("Add Action Configuration…") { configuration = .scaffold }
              .disabled(!model.canModify)
          } else {
            Button("Edit YAML…") { configuration = .edit(document) }.disabled(!model.canModify)
          }
        }
      }
      if filtered.isEmpty {
        ContentUnavailableView(
          listing.actions.isEmpty ? "No Package Actions" : "No Matching Actions",
          systemImage: "play.circle",
          description: listing.actions.isEmpty && document == nil
            ? Text("Set up a configuration in this scope to add actions.") : nil
        ).frame(maxHeight: .infinity)
      } else {
        List(selection: $selection) {
          ForEach(LifecycleEvent.allCases, id: \.self) { event in
            let eventActions = filtered.filter { $0.event == event }
            if !eventActions.isEmpty {
              Section(event.actionTitle) {
                ForEach(eventActions, id: \.selection) { action in
                  PackageActionRow(action: action).tag(action.selection)
                }
              }
            }
          }
        }.listStyle(.inset).accessibilityLabel("Configured package actions")
        if let action = filtered.first(where: { $0.selection == selection }) {
          Divider()
          LabeledContent("Configuration File") { PathView(url: action.source.file, scope: scope) }
          HStack {
            Text(verbatim: action.target).font(.caption.monospaced()).textSelection(.enabled)
            Text("Timeout \(action.timeoutSeconds) seconds")
              .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Simulate Event") {
              event = action.event
              page = .simulation
            }
          }
        }
      }
      if let reason = listing.allStartsWithheld {
        Label(reason.actionMessage, systemImage: "nosign").foregroundStyle(.secondary)
      }
      validationSection(validation ?? listing.diagnostics, checked: validation != nil)
    } else {
      ProgressView("Reading package actions…").frame(maxHeight: .infinity)
    }
  }

  private var simulationPane: some View {
    Form {
      Picker("Event", selection: $event) {
        ForEach(LifecycleEvent.allCases, id: \.self) { Text($0.actionTitle).tag($0) }
      }.disabled(working)
      if let review = simulation, simulatedEvent == event {
        Section("Simulation") {
          Text("Simulation reads your configuration. Test runs the permitted actions.")
            .foregroundStyle(.secondary)
          if let reason = review.inspection.allStartsWithheld { Text(reason.actionMessage) }
          if review.inspection.actions.isEmpty { Text("No configured actions for this event.") }
          ForEach(review.inspection.actions, id: \.selection) { action in
            PackageActionRow(action: action, runnableLabel: "Would Run")
          }
          ForEach(Array(review.inspection.diagnostics.enumerated()), id: \.offset) { _, finding in
            PackageActionFinding(finding: finding)
          }
          Button("Run Test…") { confirmTest = true }
            .disabled(working || !canTest || !review.inspection.hasRunnableActions)
            .help("Run the permitted actions shown in this simulation")
            .alert("Run Package Action Test?", isPresented: $confirmTest) {
              Button("Cancel", role: .cancel) {}
              Button("Run Test") { executeTest(review) }
            } message: {
              Text(
                "Permitted shell commands run with your access. HTTPS requests contact the servers shown."
              )
            }
        }
      } else {
        ProgressView("Simulating event…")
      }
      PackageActionResults(results: results)
    }
    .formStyle(.grouped)
    .onChange(of: event) { results = [] }
    .task(id: SimulationRequest(event: event, revision: simulationRevision)) {
      simulation = nil
      let selected = event
      let runtime = environment
      let installScope = scope.installScope
      let review = await Task.detached {
        LifecycleOperations.simulate(selected, scope: installScope, environment: runtime)
      }.value
      guard !Task.isCancelled else { return }
      simulatedEvent = selected
      simulation = review
    }
    .id(reload)
  }

  private var access: some View {
    Form {
      if scope.kind == .project, let listing {
        Section("Current Project") {
          if listing.project == nil {
            Label("Project folder unavailable", systemImage: "folder.badge.questionmark")
          } else {
            LabeledContent(
              "Package Actions", value: listing.projectTrusted ? "Enabled" : "Not Enabled")
            if !listing.projectTrusted,
              listing.actions.contains(where: { $0.source.authority == .project })
            {
              Button("Review and Enable…") { configuration = .enable }
                .disabled(!model.canModify)
            }
          }
        }
      }
      Section("Saved Project Access") {
        if let trust {
          switch trust {
          case .success(let records):
            let enabled = records.filter { $0.digest != nil }
            if enabled.isEmpty { Text("No saved project access.") }
            ForEach(enabled, id: \.project) { record in
              HStack {
                VStack(alignment: .leading, spacing: 4) {
                  PathView(url: URL(fileURLWithPath: record.project.canonicalPath))
                  if record.project == listing?.project {
                    Text("Current Project").font(.caption).foregroundStyle(.secondary)
                  } else if record.project.canonicalPath == listing?.project?.canonicalPath {
                    Text("Earlier Folder at This Path").font(.caption).foregroundStyle(.secondary)
                  } else if !FileManager.default.fileExists(atPath: record.project.canonicalPath) {
                    Text("Folder Unavailable").font(.caption).foregroundStyle(.secondary)
                  }
                }
                Spacer()
                Button("Revoke Access") { revoke(record.project) }
                  .disabled(working || model.isApplying || model.isTerminating)
                  .accessibilityLabel(
                    "Revoke package action access for \(record.project.canonicalPath)")
              }
            }
          case .failure(let error):
            Text(String(describing: error)).foregroundStyle(.red).textSelection(.enabled)
          }
        } else {
          ProgressView("Reading saved access…")
        }
      }
    }.formStyle(.grouped)
  }

  @ViewBuilder private func validationSection(_ findings: [LifecycleDiagnostic], checked: Bool)
    -> some View
  {
    if validating {
      ProgressView("Validating configuration…").controlSize(.small)
    } else if !findings.isEmpty {
      DisclosureGroup("Configuration Findings (\(findings.count))", isExpanded: $showFindings) {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
              PackageActionFinding(finding: finding)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 130)
      }
    } else if checked {
      Label("No configuration issues found.", systemImage: "checkmark.circle")
    }
  }

  private func validate() {
    validating = true
    Task {
      let findings = await Task.detached { [scope, environment] in
        LifecycleOperations.validate(scope: scope.installScope, environment: environment)
      }.value
      validation = findings
      showFindings = !findings.isEmpty
      validating = false
    }
  }

  private func executeTest(_ review: LifecycleTestReview) {
    guard canTest, review.inspection.hasRunnableActions else { return }
    messages = []
    notice = nil
    results = []
    working = model.startPackageActionEffect(
      title: "Test Package Actions", scope: scope, writes: false
    ) {
      [scope] in
      await CoreActions.executePackageActionTest(review, scope: scope)
    } receive: { completion in
      working = false
      messages = completion.diagnostics
      if case .packageActionResults(let actions) = completion.output { results = actions }
      if completion.disposition == .cancelled { notice = "Test cancelled." }
      // A second intentional test needs a fresh simulation and its own confirmation.
      simulation = nil
      simulationRevision = UUID()
    }
  }

  private func revoke(_ project: LifecycleProjectIdentity) {
    messages = []
    notice = nil
    working = model.startPackageActionEffect(
      title: "Revoke Package Actions", scope: scope, writes: true
    ) {
      [scope, environment] in
      CoreActions.revokePackageActions(project, scope: scope, environment: environment)
    } receive: { result in
      working = false
      messages = result.diagnostics
      if result.disposition == .completed {
        notice = "Saved project access revoked."
        refresh()
      }
    }
  }

  private func refresh() {
    validation = nil
    simulation = nil
    results = []
    reload = UUID()
  }
}
