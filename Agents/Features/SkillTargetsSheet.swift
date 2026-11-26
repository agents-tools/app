import AgentsCore
import AgentsUpdates
import SwiftUI

struct SkillTargetsSheet: View {
  enum Field {
    case targets
    case mode

    var title: LocalizedStringKey {
      switch self {
      case .targets: "Edit Skill Targets"
      case .mode: "Change Install Mode"
      }
    }

    var reviewTitle: LocalizedStringKey {
      switch self {
      case .targets: "Preview Skill Target Changes"
      case .mode: "Preview Install Mode Change"
      }
    }
  }

  let model: AppModel
  let item: SkillWorkspaceItem
  let field: Field
  @Environment(\.dismiss) private var dismiss
  @State private var recipients: Set<AgentID>
  @State private var mode: InstallMode?
  @State private var reviewID: UUID?

  init(model: AppModel, item: SkillWorkspaceItem, field: Field) {
    self.model = model
    self.item = item
    self.field = field
    _recipients = State(initialValue: item.targetOwner?.requestedRecipients ?? Set(item.recipients))
    _mode = State(initialValue: item.targetOwner?.skillOverride.mode)
  }

  var body: some View {
    let review = model.skillTargetsUpdateSession.flatMap { $0.id == reviewID ? $0 : nil }
    VStack(alignment: .leading, spacing: 12) {
      Text(review == nil ? field.title : field.reviewTitle)
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
    .frame(width: review == nil ? 475 : 680, height: review == nil ? editorHeight : 595)
    .interactiveDismissDisabled(model.isApplying)
    .onDisappear { closeReview() }
  }

  private var editorHeight: CGFloat { field == .targets ? 370 : 250 }

  private var editor: some View {
    let owner = model.currentSkillTargetOwner(for: item)
    return VStack(alignment: .leading, spacing: 12) {
      Form {
        switch field {
        case .targets: targetFields.disabled(owner == nil)
        case .mode:
          modeFields.disabled(owner?.canEditInstallMode != true)
        }
        if !item.canEditTargets {
          Text("This skill has no single editable declaration in this scope.")
            .foregroundStyle(.secondary)
        } else if item.scope != model.scope {
          Text("Open the skill in its owning scope to make changes.")
            .foregroundStyle(.secondary)
        } else if owner == nil && !model.readsStale {
          Text("The declaration changed. Reopen this skill to edit its current settings.")
            .foregroundStyle(.secondary)
        } else if field == .targets, let owner, Set(item.recipients) != owner.requestedRecipients {
          Text("The preview resolves these selections with the skill’s conditions.")
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Preview Changes") {
          switch field {
          case .targets: reviewID = model.previewSkillTargets(for: item, recipients: recipients)
          case .mode: reviewID = model.previewSkillInstallMode(for: item, mode: mode)
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!model.canPreviewSkillChanges || !hasChange(owner))
      }
    }
  }

  private func hasChange(_ owner: SkillTargetOwner?) -> Bool {
    guard let owner else { return false }
    switch field {
    case .targets: return recipients != owner.requestedRecipients
    case .mode: return owner.canEditInstallMode && mode != owner.skillOverride.mode
    }
  }

  private var targetFields: some View {
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
  }

  private var modeFields: some View {
    Section {
      Picker("Install Mode", selection: $mode) {
        Text(modeLabel(nil)).tag(InstallMode?.none)
        Text(InstallMode.link.skillLabel).tag(Optional(InstallMode.link))
        Text(InstallMode.copy.skillLabel).tag(Optional(InstallMode.copy))
        Text(InstallMode.edit.skillLabel).tag(Optional(InstallMode.edit))
      }
      .accessibilityIdentifier("skill.installMode")
    } footer: {
      Text("Applies to every target. Live Edit links each installation to the local source.")
    }
  }

  private func modeLabel(_ mode: InstallMode?) -> String {
    if let mode { return mode.skillLabel }
    return "Inherit (\(item.targetOwner?.inheritedMode.skillLabel ?? InstallMode.link.skillLabel))"
  }

  @ViewBuilder private func reviewContent(_ review: UpdateSession) -> some View {
    switch review.stage {
    case .preparing:
      ProgressView("Preparing preview…")
    case .review:
      if let report = review.report {
        Form {
          if field == .mode {
            LabeledContent("Install Mode", value: modeLabel(mode))
          }
          SkillTargetEffectsView(report: report, scope: item.scope)
          let changedFiles = report.instructions.targets.filter(\.changed)
          if !changedFiles.isEmpty {
            Section("Instruction Files") { InstructionFileReview(targets: changedFiles) }
          }
          if report.components.contains(where: \.changed)
            || !changedFiles.isEmpty
            || report.marketplaceChanges?.isEmpty == false
            || !report.instructions.changedPrompts.isEmpty
          {
            UpdateReportSection(report: report, scope: item.scope)
          }
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
