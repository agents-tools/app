import AgentsCore
import AgentsUpdates
import SwiftUI

struct SkillTargetsSheet: View {
  let model: AppModel
  let item: SkillWorkspaceItem
  @Environment(\.dismiss) private var dismiss
  @State private var recipients: Set<AgentID>
  @State private var reviewID: UUID?

  init(model: AppModel, item: SkillWorkspaceItem) {
    self.model = model
    self.item = item
    _recipients = State(initialValue: item.targetOwner?.requestedRecipients ?? Set(item.recipients))
  }

  var body: some View {
    let review = model.skillTargetsUpdateSession.flatMap { $0.id == reviewID ? $0 : nil }
    VStack(alignment: .leading, spacing: 12) {
      Text(review == nil ? "Edit Skill Targets" : "Preview Skill Target Changes")
        .font(.headline)
      LabeledContent("Skill") { Text(verbatim: item.title) }
      LabeledContent("Scope") { PathView(url: item.scope.root, scope: item.scope) }
      if let review {
        reviewContent(review)
      } else {
        editor
      }
    }
    .padding(24)
    .frame(width: review == nil ? 475 : 680, height: review == nil ? 370 : 595)
    .interactiveDismissDisabled(model.isApplying)
    .onDisappear { closeReview() }
  }

  private var editor: some View {
    let owner = model.currentSkillTargetOwner(for: item)
    return VStack(alignment: .leading, spacing: 12) {
      Form {
        Section("Clients") {
          ForEach(AgentID.allCases, id: \.self) { agent in
            Toggle(
              agent.displayName,
              isOn: Binding(
                get: { recipients.contains(agent) },
                set: { enabled in
                  if enabled { recipients.insert(agent) } else { recipients.remove(agent) }
                })
            )
            .toggleStyle(.checkbox)
          }
        }
        .disabled(owner == nil)
        if !item.canEditTargets {
          Text("This skill has no single editable declaration in this scope.")
            .foregroundStyle(.secondary)
        } else if item.scope != model.scope {
          Text("Open the skill in its owning scope to edit its targets.")
            .foregroundStyle(.secondary)
        } else if owner == nil && !model.readsStale {
          Text("The declaration changed. Reopen this skill to edit its current targets.")
            .foregroundStyle(.secondary)
        } else if let owner, Set(item.recipients) != owner.requestedRecipients {
          Text("The preview resolves these selections with the skill’s conditions.")
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Preview Changes") {
          reviewID = model.previewSkillTargets(for: item, recipients: recipients)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canModify || owner == nil || owner?.requestedRecipients == recipients)
      }
    }
  }

  @ViewBuilder private func reviewContent(_ review: UpdateSession) -> some View {
    switch review.stage {
    case .preparing:
      ProgressView("Preparing preview…")
    case .review:
      if let report = review.report {
        Form {
          SkillTargetEffectsView(report: report, scope: item.scope)
          bindingFields(review)
        }.formStyle(.grouped)
      }
    case .applying:
      ProgressView("Checking and applying changes…")
    case .stale:
      Text("Inputs changed. Go back and preview your selections again.")
    case .finished:
      if let terminal = review.terminal {
        Text(terminal.message)
        if let diagnostic = terminal.recovery.diagnostic { Text(verbatim: diagnostic) }
      }
    case .failed, .cancelled:
      Text(review.stage == .failed ? "The preview could not be prepared." : "Operation cancelled.")
    }
    let messages = review.messages.filter {
      $0.message != review.terminal?.message && $0.message != review.terminal?.recovery.diagnostic
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
      }.frame(maxHeight: 160)
    }
    Spacer(minLength: 0)
    HStack {
      if review.stage == .applying {
        Button("Cancel Before Apply") { model.cancelQueuedOperations() }
          .keyboardShortcut(.cancelAction)
      } else {
        let committed = review.terminal?.disposition == .committed
        Button(committed ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        if !committed {
          Button("Back") { closeReview() }
        }
        Spacer()
        if review.stage == .review {
          Button("Apply Changes") { model.confirmUpdate(id: review.id) }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canModify || !review.canApplyReport || !review.bindingsReady)
        }
      }
    }
  }

  @ViewBuilder private func bindingFields(_ review: UpdateSession) -> some View {
    if !review.requiredBindings.isEmpty {
      Section("Runtime Inputs") {
        ForEach(review.requiredBindings, id: \.self) { name in
          Toggle(
            "Supply “" + name + "”",
            isOn: Binding(
              get: { model.skillTargetsUpdateSession?.bindingInputs[name] != nil },
              set: { model.setSkillTargetsBinding($0 ? "" : nil, key: name, review: review.id) }))
          if review.bindingInputs[name] != nil {
            SecureField(
              name,
              text: Binding(
                get: { model.skillTargetsUpdateSession?.bindingInputs[name] ?? "" },
                set: { model.setSkillTargetsBinding($0, key: name, review: review.id) }))
          }
        }
      }
    }
  }

  private func closeReview() {
    if let reviewID { model.closeSkillTargetsReview(reviewID) }
    reviewID = nil
  }
}
