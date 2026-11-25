import AgentsCore
import SwiftUI

struct SectionsEditor: View {
  @Binding var values: [SectionDeclaration]
  var allowsAntigravity = false

  var body: some View {
    DraftRows(values: $values) { row, actions in
      DisclosureGroup(row.wrappedValue.name.isEmpty ? "New Section" : row.wrappedValue.reference) {
        TextField("Name", text: row.name)
        OptionalText(title: "source", value: row.source)
        ConditionEditor(
          value: row.condition,
          agentTitle: allowsAntigravity ? "Restrict recipients" : "Specify agents",
          allowsAntigravity: allowsAntigravity)
        DraftRowButtons(actions: actions)
      }
    }
    Button("Add Section") { values.append(.init(name: "")) }
  }
}

struct InstructionDraftEditor: View {
  @Binding var value: InstructionsDeclaration
  let allowsAntigravity: Bool

  var body: some View {
    DisclosureGroup("Ordered Sections") {
      if allowsAntigravity {
        Text("Use a section’s conditions to restrict which installation targets receive it.")
          .font(.caption).foregroundStyle(.secondary)
      }
      SectionsEditor(values: $value.sectionReferences, allowsAntigravity: allowsAntigravity)
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
          AgentsEditor(value: row.override.agents)
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
