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
          Text("Waiting for the operation, including recovery and cleanup, to finish.")
            .foregroundStyle(.secondary)
        case .review:
          if let report = session.report {
            Form {
              UpdateReportSection(report: report, scope: session.proposal.scope)
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
        ForEach(
          session.messages.filter {
            $0.message != session.terminal?.message
              && $0.message != session.terminal?.recovery.diagnostic
          }
        ) { message in
          Text(message.message).foregroundStyle(message.severity == .error ? .red : .secondary)
        }
        HStack {
          Button(model.isApplying ? "Cancel Before Apply" : session.closeTitle) {
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
        .sheet(item: $model.assistanceSession) { _ in AssistanceView(model: model) }
        .interactiveDismissDisabled(model.isApplying)
    }
  }
}

private struct UpdateReportSection: View {
  let report: CombinedUpdateReport
  let scope: WorkspaceScope
  var body: some View {
    Section("Proposed Changes") {
      Text(report.hasChanges ? "Review the changes below." : "No changes are needed.")
      ForEach(Array(report.skills.enumerated()), id: \.offset) { _, skill in
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
      ForEach(Array(report.instructions.targets.enumerated()), id: \.offset) { _, target in
        DetailsGroup("Instructions · " + target.target) {
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
