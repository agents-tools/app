import AgentsCore
import AgentsUpdates
import SwiftUI

struct UpdateReviewView: View {
  @Bindable var model: AppModel
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
          Text("Waiting for the complete Core operation, including recovery and cleanup.")
            .foregroundStyle(.secondary)
        case .review:
          if let report = session.report {
            UpdateReportView(report: report, scope: session.proposal.scope)
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
              "Apply prepares again and checks this exact preview. Changed inputs require a new review."
            )
            .font(.caption).foregroundStyle(.secondary)
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
        ForEach(session.messages) { message in
          Text(message.message).foregroundStyle(message.severity == .error ? .red : .secondary)
        }
        HStack {
          Button(model.isApplying ? "Cancel Before Apply" : "Done") {
            if model.isApplying {
              model.cancelQueuedOperations()
            } else {
              model.closeUpdateReview()
            }
          }.keyboardShortcut(.cancelAction)
          Spacer()
          if case .review = session.stage {
            Button("Apply Changes") { model.confirmUpdate() }
              .disabled(
                !model.canModify || !session.bindingsReady || session.report?.hasChanges != true
              )
              .keyboardShortcut(.defaultAction)
          }
        }
      }.padding(24).frame(width: 680, height: 620)
        .interactiveDismissDisabled(model.isApplying)
        .textSelection(.enabled)
    }
  }
}

struct UpdateReportView: View {
  let report: CombinedUpdateReport
  let scope: WorkspaceScope
  var body: some View {
    Form {
      Section("Proposed Changes") {
        Text(report.hasChanges ? "Core has prepared changes for review." : "No changes are needed.")
        if report.lockMissing { Text("Resolved state will be reconstructed.") }
        ForEach(Array(report.skills.enumerated()), id: \.offset) { _, skill in
          DisclosureGroup("Skill · " + skill.skill) {
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
        ForEach(Array(report.instructions.targets.enumerated()), id: \.offset) { _, target in
          DisclosureGroup("Instructions · " + target.target) {
            LabeledContent("Status", value: target.changed ? "Changed" : "Unchanged")
            LabeledContent("Location") { PathView(url: target.url, scope: scope) }
            LabeledContent(
              "Agents", value: target.afterAgents.map(\.displayName).joined(separator: ", "))
            if target.foreign {
              Label("Existing unmanaged content", systemImage: "exclamationmark.triangle")
            }
          }
        }
        ForEach(report.instructions.changedPrompts, id: \.self) { Text("Named prompt · " + $0) }
        ForEach(Array(report.components.enumerated()), id: \.offset) { _, change in
          DisclosureGroup(DeclarationLabels.kind(change.kind) + " · " + change.name) {
            LabeledContent("Status", value: change.changed ? "Changed" : "Unchanged")
            LabeledContent("Target") {
              PathView(url: URL(fileURLWithPath: change.path), scope: scope)
            }
            LabeledContent("Format", value: change.format)
            LabeledContent("Ownership", value: change.ownership)
            LabeledContent(
              "Readers", value: change.effectiveReaders.map(\.displayName).joined(separator: ", "))
            if change.privateMaterialization {
              Label("Private materialization", systemImage: "lock")
            }
            if !change.requiredBindings.isEmpty {
              LabeledContent(
                "Required bindings", value: change.requiredBindings.joined(separator: ", "))
            }
            if let permission = change.permissionChange {
              LabeledContent(
                "File mode",
                value: String(permission.beforeMode, radix: 8) + " → "
                  + String(permission.afterMode, radix: 8))
              LabeledContent(
                "Owner",
                value: String(permission.beforeOwner) + " → " + String(permission.afterOwner))
            }
            if let before = change.symbolicBefore {
              DisclosureGroup("Before") { Text(before).font(.system(.body, design: .monospaced)) }
            }
            if let after = change.symbolicAfter {
              DisclosureGroup("After") { Text(after).font(.system(.body, design: .monospaced)) }
            }
            ForEach(Array(change.resources.enumerated()), id: \.offset) { _, resource in
              LabeledContent("Resource", value: resource.path)
            }
          }
        }
      }
    }.formStyle(.grouped)
  }
}

struct ChangesView: View {
  @Bindable var model: AppModel
  @State private var selection: Set<ComponentSelection> = []
  var body: some View {
    Form {
      Section("Configuration") {
        Button("Edit Configuration…") { model.beginDraft(.defaults) }
        Button("Preview Full Update…") { model.previewUpdate(title: "Update Configuration") }
        Button("Preview Restore…") {
          model.previewUpdate(title: "Restore Managed Outputs", request: .init(operation: .restore))
        }
      }.disabled(!model.canModify)
      Section("Managed Components") {
        if model.availableComponentSelection.isEmpty { Text("No managed components are recorded.") }
        ForEach(model.availableComponentSelection, id: \.record) { component in
          Toggle(
            isOn: Binding(
              get: { selection.contains(component.selection) },
              set: {
                if $0 {
                  selection.insert(component.selection)
                } else {
                  selection.remove(component.selection)
                }
              })
          ) {
            VStack(alignment: .leading) {
              Text(DeclarationLabels.kind(component.kind.rawValue) + " · " + component.name)
              Text(component.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .truncationMode(.middle).help(component.source)
            }
          }
        }
        Button("Preview Selected Update…") {
          model.previewUpdate(
            title: "Update Selected Components", request: .init(selections: Array(selection)))
        }.disabled(selection.isEmpty || !model.canModify)
        Button("Preview Selected Removal…") {
          model.previewUpdate(
            title: "Remove Selected Components",
            request: .init(operation: .remove, selections: Array(selection)))
        }.disabled(selection.isEmpty || !model.canModify)
      }
      Section("Operation Results") {
        ForEach(model.updateRecords.filter { $0.scope == model.scope }) { record in
          LabeledContent(record.title, value: record.terminal.message)
        }
      }
    }.formStyle(.grouped)
      .onChange(of: model.snapshot?.inspection.generation) { selection.removeAll() }
  }
}
