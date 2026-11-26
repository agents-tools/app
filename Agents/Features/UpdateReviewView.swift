import AgentsCore
import AgentsInstructions
import AgentsUpdates
import SwiftUI

struct UpdateReviewView: View {
  @Bindable var model: AppModel

  private var isInstructionDraft: Bool {
    model.manifestDraft?.kind == .component && model.manifestDraft?.component.kind == .instructions
  }

  var body: some View {
    if let session = model.updateSession {
      VStack(alignment: .leading, spacing: 12) {
        Text(session.proposal.title).font(.headline)
        LabeledContent("Scope") {
          PathView(url: session.proposal.scope.root, scope: session.proposal.scope)
        }
        switch session.stage {
        case .preparing, .applying:
          ProgressView(
            session.stage == .applying ? "Preparing again and applying…" : "Preparing preview…")
          Text("Waiting for the operation, including recovery and cleanup, to finish.")
            .foregroundStyle(.secondary)
        case .review:
          if let report = session.report {
            Form {
              if session.isInstructionBuild || isInstructionDraft {
                Section("Built Outputs") {
                  InstructionBuildBrowser(
                    outputs: report.instructions.outputs, scope: session.proposal.scope
                  ).id(session.id)
                }
              }
              if let draft = model.manifestDraft, let proposed = draft.yaml {
                Section("Configuration File") {
                  if let location = model.snapshot?.manifestURL { PathView(url: location, scope: draft.scope) }
                  if let document = draft.document {
                    DetailsGroup("Current YAML") {
                      Text(verbatim: String(decoding: document.bytes, as: UTF8.self)).font(.body.monospaced()).textSelection(.enabled)
                    }
                  }
                  DetailsGroup("Proposed YAML") {
                    Text(verbatim: proposed).font(.body.monospaced()).textSelection(.enabled)
                  }
                }
              }
              if let change = report.marketplaceGraphChange {
                MarketplaceGraphReview(change: change)
              }
              if !report.instructions.targets.isEmpty || !report.instructions.advisories.isEmpty
                || !report.instructions.conflicts.isEmpty
              {
                Section("Instruction Files") {
                  ForEach(Array(report.instructions.conflicts.enumerated()), id: \.offset) {
                    _, conflict in
                    Label {
                      Text(verbatim: conflict).textSelection(.enabled)
                    } icon: {
                      Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.red)
                  }
                  ForEach(report.instructions.advisories, id: \.self) { advisory in
                    Text(verbatim: advisory).foregroundStyle(.secondary)
                  }
                  if !report.instructions.targets.isEmpty {
                    if session.isInstructionBuild || isInstructionDraft {
                      DetailsGroup("Review Local Files") {
                        InstructionFileReview(targets: report.instructions.targets)
                      }
                    } else {
                      InstructionFileReview(targets: report.instructions.targets)
                    }
                  }
                }
              }
              TargetAssignmentChanges(report: report)
              UpdateReportSection(report: report, scope: session.proposal.scope)
              if let review = session.packageReview {
                PackageActionPreview(inspection: review.lifecycle).id(session.id)
              }
              if model.assistanceAvailable {
                HStack {
                  Button("Summarize Update…") {
                    model.reviewAssistance(.changes(report, action: .summarizeUpdate))
                  }
                  Button("Explain Configuration Changes…") {
                    model.reviewAssistance(.changes(report, action: .explainConfiguration))
                  }
                }
              }
              if !session.requiredBindings.isEmpty {
                Text("Runtime inputs are used for this apply only.").font(.caption).foregroundStyle(
                  .secondary)
                ForEach(session.requiredBindings, id: \.self) { name in
                  Toggle(
                    "Supply “" + name + "”",
                    isOn: Binding(
                      get: { model.updateSession?.bindingInputs[name] != nil },
                      set: { model.updateSession?.bindingInputs[name] = $0 ? "" : nil }))
                  if session.bindingInputs[name] != nil {
                    SecureField(
                      name,
                      text: Binding(
                        get: { model.updateSession?.bindingInputs[name] ?? "" },
                        set: { model.updateSession?.bindingInputs[name] = $0 }))
                  }
                }
              }
              Text(
                "Changes to the inputs require another review before applying."
              )
              .font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
          }
        case .stale: Text("Configuration or scope changed. Prepare a new preview before applying.")
        case .cancelled:
          Text(session.terminal?.message ?? "Cancelled before the operation started.")
        case .finished, .failed:
          if let terminal = session.terminal {
            Text(terminal.message)
            if let diagnostic = terminal.recovery.diagnostic { Text(diagnostic) }
          }
        }
        if let terminal = session.terminal {
          PackageActionResults(results: terminal.packageActions)
        }
        let messages = session.messages.filter {
          $0.message != session.terminal?.message
            && $0.message != session.terminal?.recovery.diagnostic
        }
        if !messages.isEmpty {
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(messages) { message in
                Text(verbatim: message.message)
                  .foregroundStyle(message.severity == .error ? .red : .secondary)
                  .textSelection(.enabled)
                if let path = message.path { PathView(url: URL(fileURLWithPath: path)) }
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.defaultScrollAnchor(.top).frame(maxHeight: 180)
        }
        HStack {
          Button(model.isApplying ? session.applyingCancelTitle : session.closeTitle) {
            if model.isApplying {
              model.cancelQueuedOperations()
            } else {
              model.closeUpdateReview()
            }
          }.keyboardShortcut(.cancelAction)
          Spacer()
          if session.stage == .review, session.offersApply {
            Button(applyTitle(session)) {
              model.confirmUpdate()
            }
            .disabled(!model.canModify || !session.bindingsReady || !session.canApplyReport)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("update.apply")
          }
        }
      }.padding(24).frame(width: 680, height: 620)
        .sheet(item: $model.assistanceSession) { _ in AssistanceView(model: model) }
        .interactiveDismissDisabled(model.isApplying)
    }
  }

  private func applyTitle(_ session: UpdateSession) -> String {
    if session.report?.hasChanges == false { return "Run Package Actions" }
    if isInstructionDraft {
      let changesLocalFiles = session.report?.instructions.targets.contains {
        $0.changed || $0.agentsChanged
      }
      return changesLocalFiles == true ? "Save and Apply Local Changes" : "Save Declaration"
    }
    return session.isInstructionBuild ? "Apply Local Changes" : "Apply Changes"
  }
}

private struct TargetAssignmentChanges: View {
  let report: CombinedUpdateReport

  private struct Change: Hashable {
    let item: String
    let source: String
    let action: String
  }

  var body: some View {
    let changes = assignments
    if !changes.isEmpty {
      Section("Target Assignment Changes") {
        ForEach(AgentID.allCases, id: \.self) { client in
          if let items = changes[client] {
            VStack(alignment: .leading, spacing: 4) {
              Text(client.displayName).font(.headline)
              ForEach(Array(items.enumerated()), id: \.offset) { _, change in
                LabeledContent(change.item, value: change.action)
                  .help(change.source)
              }
            }
          }
        }
      }
    }
  }

  private var assignments: [AgentID: [Change]] {
    var result: [AgentID: [Change]] = [:]
    for skill in report.skills {
      for member in skill.membership where member.before != member.after {
        let action: String
        switch (member.before, member.after) {
        case (.absent, .installed): action = "Add"
        case (.installed, .absent): action = "Remove"
        case (_, .installed(let mode)): action = "Change to " + mode.rawValue
        default: continue
        }
        result[member.agent, default: []].append(
          Change(item: skill.skill, source: skill.sourceIdentity, action: action))
      }
    }
    for target in report.instructions.targets where target.agentsChanged {
      let old = Set(target.beforeAgents ?? [])
      let new = Set(target.afterAgents)
      for client in old.symmetricDifference(new) {
        result[client, default: []].append(
          Change(item: target.target, source: target.url.path, action: new.contains(client) ? "Add" : "Remove"))
      }
    }
    return result
  }
}

struct UpdateReportSection: View {
  let report: CombinedUpdateReport
  let scope: WorkspaceScope
  var body: some View {
    Section("Proposed Changes") {
      if !report.hasChanges && report.instructions.conflicts.isEmpty {
        Text("No changes are needed.")
      }
      ForEach(Array((report.marketplaceChanges ?? []).enumerated()), id: \.offset) { _, change in
        if let pin = change.after ?? change.before {
          DetailsGroup("Package · " + pin.dependency.name) {
            if let before = change.before { packageRelease("Installed", pin: before) }
            if let after = change.after { packageRelease("Proposed", pin: after) }
          }
        }
      }
      ForEach(Array(report.skills.filter(\.changed).enumerated()), id: \.offset) { _, skill in
        DetailsGroup("Skill · " + skill.skill) {
          LabeledContent("Status", value: skill.changed ? "Changed" : "Unchanged")
          LabeledContent("Source") { CompactText(text: skill.sourceIdentity) }
          if let revision = skill.newRevision {
            LabeledContent("Revision") { CompactText(text: revision) }
          }
          ForEach(Array(skill.membership.enumerated()), id: \.offset) { _, membership in
            LabeledContent(membership.agent.displayName) {
              PathView(url: URL(fileURLWithPath: membership.path), scope: scope)
            }
          }
          ForEach(Array(skill.changes.enumerated()), id: \.offset) { _, file in
            LabeledContent(
              file.before == nil ? "Add" : (file.after == nil ? "Remove" : "Change"),
              value: file.path)
          }
        }
      }
      ForEach(report.instructions.changedPrompts, id: \.self) { Text("Named prompt · " + $0) }
      ForEach(Array(report.components.filter(\.changed).enumerated()), id: \.offset) { _, change in
        DetailsGroup(DeclarationLabels.kind(change.kind) + " · " + change.name) {
          LabeledContent("Status", value: change.changed ? "Changed" : "Unchanged")
          LabeledContent("Target") {
            PathView(url: URL(fileURLWithPath: change.path), scope: scope)
          }
          LabeledContent(
            "Readers", value: change.effectiveReaders.map(\.displayName).joined(separator: ", "))
          if change.privateMaterialization {
            Label("Private materialization", systemImage: "lock")
          }
          if !change.requiredBindings.isEmpty {
            LabeledContent(
              "Required bindings", value: change.requiredBindings.joined(separator: ", "))
          }
          SymbolicChangeView(title: "Before", text: change.symbolicBefore)
          SymbolicChangeView(title: "After", text: change.symbolicAfter)
          if let permission = change.permissionChange {
            LabeledContent(
              "File mode",
              value: String(permission.beforeMode, radix: 8) + " → "
                + String(permission.afterMode, radix: 8))
            LabeledContent(
              "Owner",
              value: String(permission.beforeOwner) + " → " + String(permission.afterOwner))
          }
          ForEach(Array(change.resources.enumerated()), id: \.offset) { _, resource in
            LabeledContent("Resource", value: resource.path)
          }
        }
      }
    }
  }

  private func packageRelease(_ title: LocalizedStringKey, pin: MarketplacePin) -> some View {
    LabeledContent(title) {
      VStack(alignment: .trailing) {
        Text(verbatim: pin.dependency.coordinate.package + "@" + pin.dependency.coordinate.version)
        CompactText(text: pin.archiveDigest).font(.caption.monospaced())
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(
      Text(
        verbatim: pin.dependency.coordinate.package + " " + pin.dependency.coordinate.version + ", "
          + pin.archiveDigest))
  }
}

struct InstructionFileReviewRow: Identifiable {
  let target: InstructionTargetChange
  var id: URL { target.url }

  var action: String {
    if target.after == nil && target.afterAgents.isEmpty
      && (target.before != nil || target.beforeAgents != nil)
    {
      return "Remove"
    }
    if target.before == nil && target.after != nil { return "Add" }
    if target.changed { return "Update" }
    if target.agentsChanged && target.beforeAgents != nil { return "Update recipients" }
    return "Unchanged"
  }

  var verification: String {
    if target.foreign { return "Conflict" }
    switch target.drift {
    case .clean: return "Matches lock"
    case .missing: return "Missing"
    case .drifted: return "Modified"
    case nil: return "No prior lock"
    }
  }
}

struct InstructionFileReview: View {
  let targets: [InstructionTargetChange]
  @State private var selection: URL?

  var body: some View {
    let rows = targets.map(InstructionFileReviewRow.init(target:))
    VSplitView {
      Table(rows, selection: $selection) {
        TableColumn("Path") { row in
          PathView(url: row.target.url).monospaced()
        }
        TableColumn("Change") { row in Text(row.action) }.width(110)
        TableColumn("Verification") { row in
          Text(row.verification).foregroundStyle(row.target.foreign ? .red : .primary)
        }.width(98)
        TableColumn("New size") { row in
          if let count = row.target.after?.count {
            Text("\(count.formatted()) B").monospacedDigit()
              .accessibilityLabel("\(count.formatted()) bytes")
          } else {
            Text("—").foregroundStyle(.secondary)
          }
        }.width(74)
      }
      .frame(minHeight: 124, idealHeight: 158)
      if let row = rows.first(where: { $0.id == selection }) {
        detail(row.target).frame(minHeight: 125, idealHeight: 165)
      }
    }
    .frame(height: 330)
    .onChange(of: targets.map(\.url), initial: true) { _, paths in
      if selection.map(paths.contains) != true { selection = paths.first }
    }
  }

  private func detail(_ target: InstructionTargetChange) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      PathView(url: target.url).monospaced()
      let agents = target.afterAgents.isEmpty ? (target.beforeAgents ?? []) : target.afterAgents
      if !agents.isEmpty {
        LabeledContent("Recipients", value: agents.map(\.displayName).joined(separator: ", "))
      }
      if target.foreign {
        Label("Existing unmanaged content", systemImage: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
      HSplitView {
        fileText("Before", bytes: target.before)
        fileText("After", bytes: target.after)
      }
    }.padding(8)
  }

  private func fileText(_ title: String, bytes: Data?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      if let bytes, let text = String(data: bytes, encoding: .utf8) {
        ScrollView {
          Text(verbatim: text).monospaced().textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        Text(bytes == nil ? "No file" : "Text unavailable").foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
    }
    .frame(minWidth: 155, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(.horizontal, 4)
  }
}

struct ChangesView: View {
  @Bindable var model: AppModel
  @State private var selection: Set<ComponentSelection> = []
  @State private var showingPatches = false
  @State private var showingHistory = false
  private struct Row: Identifiable {
    let component: ComponentInspection
    var id: String { component.record }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("View", selection: $showingHistory) {
          Text("Changes").tag(false)
          Text("History").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        Spacer()
        if !showingHistory {
          Menu("Configuration") {
            Button("Configure Default Clients…") { model.beginDraft(.defaults) }
            Button("Preview Full Update…") {
              model.previewUpdate(title: "Update Configuration", intent: .update)
            }
            Button("Preview Restore…") {
              model.previewUpdate(title: "Restore Managed Outputs", request: .init(operation: .restore))
            }
          }.fixedSize().disabled(!model.canModify)
          Button("Export Patches…") { showingPatches = true }
        }
      }
      .padding()
      Divider()
      if showingHistory {
        let records = model.updateRecords.filter { $0.scope == model.scope }
        if records.isEmpty {
          ContentUnavailableView("No Operations This Session", systemImage: "clock")
        } else {
          List(records.reversed()) { record in
            LabeledContent(record.title, value: record.terminal.message)
          }
          .listStyle(.inset)
        }
      } else if model.availableComponentSelection.isEmpty {
        ContentUnavailableView("No Installed Components", systemImage: "square.stack.3d.up")
      } else {
        componentTable
        Divider()
        HStack {
          Text("\(selection.count) selected").foregroundStyle(.secondary)
          Spacer()
          Button("Preview Removal…") {
            model.previewUpdate(
              title: "Remove Selected Components",
              request: .init(operation: .remove, selections: Array(selection)))
          }
          Button("Preview Update…") {
            model.previewUpdate(
              title: "Update Selected Components", request: .init(selections: Array(selection)))
          }
        }
        .disabled(selection.isEmpty || !model.canModify)
        .padding()
      }
    }
      .sheet(isPresented: $showingPatches) {
        ProducerPatchSheet(
          scope: model.scope.installScope, environment: model.actions.environment(for: model.scope)
        )
        .id(model.scope.id)
      }
      .onChange(of: model.scope.id) { selection.removeAll() }
      .onChange(of: model.snapshot?.inspection.generation) { selection.removeAll() }
  }

  private var componentTable: some View {
    Table(model.availableComponentSelection.map(Row.init)) {
      TableColumn("Component") { row in
        Toggle(row.component.name, isOn: Binding(
          get: { selection.contains(row.component.selection) },
          set: { included in
            if included { selection.insert(row.component.selection) }
            else { selection.remove(row.component.selection) }
          }))
          .toggleStyle(.checkbox)
      }
      TableColumn("Kind") { row in Text(DeclarationLabels.kind(row.component.kind.rawValue)) }
      TableColumn("Clients") { row in
        Text(row.component.recipients.map(\.displayName).joined(separator: ", ")).lineLimit(1)
      }
      TableColumn("Source") { row in CompactText(text: row.component.source) }
    }
    .accessibilityIdentifier("changes.components")
  }

}

struct SymbolicChangeView: View {
  let title: String
  let text: String?
  var body: some View {
    DetailsGroup(title) {
      if let text {
        ScrollView {
          Text(verbatim: text).font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }.frame(maxHeight: 220)
      } else {
        Text("Not available").foregroundStyle(.secondary)
      }
    }
  }
}
