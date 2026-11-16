import AgentsCore
import SwiftUI

struct SectionsEditor: View {
  @Binding var values: [SectionDeclaration]
  var body: some View {
    DraftRows(values: $values) { row, actions in
      DisclosureGroup(row.wrappedValue.name.isEmpty ? "New Section" : row.wrappedValue.reference) {
        TextField("Name", text: row.name)
        OptionalText(title: "source", value: row.source)
        ConditionEditor(value: row.condition)
        DraftRowButtons(actions: actions)
      }
    }
    Button("Add Section") { values.append(.init(name: "")) }
  }
}

struct InstructionDraftEditor: View {
  @Binding var value: InstructionsDeclaration
  var body: some View {
    DisclosureGroup("Ordered Sections") { SectionsEditor(values: $value.sectionReferences) }
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
