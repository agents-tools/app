import AgentsCore
import SwiftUI

struct SectionsEditor: View {
  @Binding var values: [SectionDeclaration]
  var instructionScope: InstallScope?
  var defaultAgents: [AgentID] = []

  var body: some View {
    DraftRows(values: $values) { row, actions in
      DisclosureGroup(row.wrappedValue.name.isEmpty ? "New Section" : row.wrappedValue.reference) {
        TextField("Name", text: row.name)
        OptionalText(title: "source", value: row.source)
        if let instructionScope {
          InstructionRecipientsEditor(
            section: row, scope: instructionScope, defaultAgents: defaultAgents
          )
        }
        ConditionEditor(value: row.condition, showsAgents: instructionScope == nil)
        DraftRowButtons(actions: actions)
      }
    }
    Button("Add Section") { values.append(.init(name: "")) }
  }
}

struct InstructionRecipientsEditor: View {
  @Binding var section: SectionDeclaration
  let scope: InstallScope
  let defaultAgents: [AgentID]

  @State private var showsRecipients = false

  private var localRecipients: [InstructionRecipient] {
    AgentID.allCases.filter { $0.supportsInstructions(in: scope) }.map(InstructionRecipient.local)
  }

  private var summary: String {
    let names = selection.map(\.displayName).joined(separator: ", ")
    if section.recipients == nil {
      return names.isEmpty ? "Defaults" : "Defaults · " + names
    }
    return names.isEmpty ? "No Recipients" : names
  }

  private var selection: [InstructionRecipient] {
    let requested = section.recipients ?? defaultAgents
      .filter { $0.supportsInstructions(in: scope) }
      .map(InstructionRecipient.local)
    guard let restricted = section.condition?.agents else { return requested }
    return requested.filter {
      if case .local(let agent) = $0 { return restricted.contains(agent) }
      return true
    }
  }

  var body: some View {
    LabeledContent("Recipients") {
      Button {
        showsRecipients.toggle()
      } label: {
        HStack(spacing: 6) {
          Text(summary).lineLimit(1)
          Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            .accessibilityHidden(true)
        }
      }
      .accessibilityLabel("Recipients")
      .accessibilityValue(summary)
      .accessibilityIdentifier("instructions.recipients." + section.reference)
      .popover(isPresented: $showsRecipients, arrowEdge: .trailing) {
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Use Defaults", isOn: usesDefaults)
          Divider()
          Text("Local Clients").font(.caption).foregroundStyle(.secondary)
          ForEach(localRecipients, id: \.self) { recipient in
            Toggle(recipient.displayName, isOn: selection(for: recipient))
          }
          Text("Copy Only").font(.caption).foregroundStyle(.secondary)
          ForEach([InstructionRecipient.chatGPTApp, .geminiApp], id: \.self) { recipient in
            Toggle(recipient.displayName, isOn: selection(for: recipient))
          }
        }
        .toggleStyle(.checkbox)
        .frame(minWidth: 180, alignment: .leading)
        .padding(12)
      }
    }
  }

  var usesDefaults: Binding<Bool> {
    Binding(
      get: { section.recipients == nil },
      set: { inherited in
        if inherited { section.recipients = nil } else { setSelection(selection) }
      })
  }

  func selection(for recipient: InstructionRecipient) -> Binding<Bool> {
    Binding(
      get: { selection.contains(recipient) },
      set: { isSelected in
        var explicit = selection
        guard explicit.contains(recipient) != isSelected else { return }
        if isSelected {
          explicit.append(recipient)
        } else {
          explicit.removeAll { $0 == recipient }
        }
        setSelection(explicit)
      })
  }

  private func setSelection(_ recipients: [InstructionRecipient]) {
    var edited = section
    edited.recipients = recipients
    // Move legacy section-level agent restrictions into the explicit selection.
    if edited.condition?.agents != nil {
      edited.condition?.agents = nil
      if edited.condition == DeclarationCondition() { edited.condition = nil }
    }
    section = edited
  }
}

struct InstructionDraftEditor: View {
  @Binding var value: InstructionsDeclaration
  let scope: InstallScope
  let defaultAgents: [AgentID]

  @State private var orderedSectionsExpanded = true

  var body: some View {
    DisclosureGroup("Ordered Sections", isExpanded: $orderedSectionsExpanded) {
      Text("Choose recipients for each section or use the configured defaults.")
        .font(.caption).foregroundStyle(.secondary)
      SectionsEditor(
        values: $value.sectionReferences, instructionScope: scope, defaultAgents: defaultAgents)
    }
    DisclosureGroup("Named Prompts") {
      DraftRows(values: $value.prompts) { row, actions in
        DisclosureGroup(row.wrappedValue.name.isEmpty ? "New Prompt" : row.wrappedValue.name) {
          TextField("Name", text: row.name)
          SectionsEditor(values: row.prompt.sectionReferences)
          OptionalText(title: "append path", value: row.prompt.append)
          ConditionEditor(value: row.prompt.condition)
          DraftRowButtons(actions: actions)
        }
      }
      Button("Add Prompt") { value.prompts.append(.init(name: "", prompt: .init(sections: []))) }
    }
  }
}

struct SkillDraftEditor: View {
  @Binding var value: SkillDeclaration
  var body: some View {
    OptionalText(title: "skill search path", value: $value.path)
    Text("Relative to the source’s discovery root.").font(.caption).foregroundStyle(.secondary)
    Toggle(
      "Select all skills",
      isOn: Binding(
        get: {
          if case .all = value.select { return true }
          return false
        },
        set: {
          value.select = $0 ? .all : .names([])
        }))
    if case .names(let names) = value.select {
      LinesEditor(
        title: "Selected skills",
        values: Binding(get: { names }, set: { value.select = .names($0) }))
    }
    OptionalLines(title: "exclusions", values: $value.exclude)
    ModeEditor(value: $value.mode)
    DisclosureGroup("Per-Skill Overrides") {
      DraftRows(values: $value.overrideDeclarations) { row, actions in
        DisclosureGroup(row.wrappedValue.name.isEmpty ? "New Override" : row.wrappedValue.name) {
          TextField("Skill name", text: row.name)
          AgentsEditor(value: row.override.agents, allowsAntigravity: AgentID.antigravity.supportsSkills)
          ModeEditor(value: row.override.mode)
          DraftRowButtons(actions: actions)
        }
      }
      Button("Add Override") {
        value.overrideDeclarations.append(.init(name: "", override: .init()))
      }
    }
  }
}

struct ModeEditor: View {
  @Binding var value: InstallMode?
  var body: some View {
    Toggle(
      "Specify install mode",
      isOn: Binding(get: { value != nil }, set: { value = $0 ? .link : nil }))
    if value != nil {
      Picker("Mode", selection: Binding(get: { value ?? .link }, set: { value = $0 })) {
        Text("Link").tag(InstallMode.link)
        Text("Copy").tag(InstallMode.copy)
        Text("Edit").tag(InstallMode.edit)
      }
    }
  }
}
