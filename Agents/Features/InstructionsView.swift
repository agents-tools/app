import AgentsUpdates
import AppKit
import SwiftUI

struct InstructionsView: View {
  @Bindable var model: AppModel
  let snapshot: WorkspaceSnapshot

  @State private var mappingID: String?
  @State private var targetID: String?

  var body: some View {
    Form {
      Section("Instruction Sources") {
        if snapshot.instructions.isEmpty {
          Text("No instruction components are declared.").foregroundStyle(.secondary)
        }
        ForEach(snapshot.instructions) { item in
          DisclosureGroup {
            RecordFields(
              record: item.record, pointer: item.pointer,
              authored: snapshot.document.map { AuthoredFields(sourceMap: $0.sourceMap) })
            Button("Edit Instructions…") {
              model.selectedItem = item.id
              model.editSelectedDeclaration()
            }.disabled(!model.canModify)
            ForEach(
              item.record["chatGPT"]?.elements?.compactMap(\.record).compactMap {
                $0["name"]?.string
              } ?? [], id: \.self
            ) { name in
              Button("Generate “\(name)”…") { model.previewPrompt(name: name, in: snapshot.scope) }
            }
          } label: {
            Label(item.container, systemImage: "doc.text")
          }
        }
      }
      if model.scope.kind == .project {
        Section("Local Instructions") {
          if let own = snapshot.ownInstructions {
            if own.isEmpty {
              Text("No local instructions found.").foregroundStyle(.secondary)
            }
            ForEach(own) { item in
              DisclosureGroup(item.heading) {
                Text(item.description)
                LabeledContent("Location") { PathView(url: item.authorFile, scope: model.scope) }
                LabeledContent("Paths", value: item.paths.joined(separator: ", "))
                Button("Open Author File") { NSWorkspace.shared.open(item.authorFile) }
              }
            }
          } else {
            Text("Local instructions are unavailable. See Diagnostics.").foregroundStyle(.secondary)
          }
        }
      }
      let rules = snapshot.inspection.deployments.filter {
        $0.format == "agents/antigravity-rule@1"
      }
      if !rules.isEmpty {
        Section("Installed Antigravity Rules") {
          ForEach(rules, id: \.identity) { rule in
            LabeledContent {
              Text(rule.status == .current ? "Verified" : rule.status.rawValue.capitalized)
                .foregroundStyle(rule.status == .current ? .secondary : .primary)
            } label: {
              PathView(url: rule.location, scope: snapshot.scope)
            }
            if let diagnostic = rule.diagnostic {
              Text(verbatim: diagnostic).foregroundStyle(.secondary)
            }
          }
        }
      }
      if let mapping = snapshot.mappings.first(where: { $0.id == mappingID })
        ?? snapshot.mappings.first
      {
        Section("Instruction Output") {
          if snapshot.mappings.count > 1 {
            Picker(
              "Configuration",
              selection: Binding(
                get: { mapping.id },
                set: {
                  mappingID = $0
                  targetID = nil
                })
            ) {
              ForEach(snapshot.mappings) { item in Text(item.title).tag(item.id) }
            }
          }
          Text(mapping.status).foregroundStyle(.secondary)
          if let target = mapping.targets.first(where: { $0.id == targetID })
            ?? mapping.targets.first
          {
            Picker("Output file", selection: Binding(get: { target.id }, set: { targetID = $0 })) {
              ForEach(mapping.targets) { item in Text(item.id).tag(item.id) }
            }
            LabeledContent("Used by", value: target.agents)
            if let imported = target.importedFile {
              LabeledContent("Imports", value: imported)
            }
          }
          Button("Copy Mapping") { copyText(mapping.copyText) }
        }
        if let target = mapping.targets.first(where: { $0.id == targetID })
          ?? mapping.targets.first,
          !target.sections.isEmpty
        {
          Section("Sections in File Order") { orderedSections(target.sections) }
        }
        if !mapping.unplaced.isEmpty {
          Section("Unassigned Sections") { orderedSections(mapping.unplaced) }
        }
        if !mapping.prompts.isEmpty {
          Section("Named Prompts") {
            ForEach(mapping.prompts.keys.sorted(), id: \.self) { name in
              HStack {
                Text(name)
                Spacer()
                Button("Preview…") { model.previewPrompt(name: name, in: mapping.scope) }
                  .accessibilityLabel("Preview " + name)
              }
              if let sections = mapping.prompts[name], !sections.isEmpty {
                Text(sections.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .textSelection(.enabled)
    .toolbar {
      ToolbarItem {
        Button("Preview Instruction Changes…") {
          model.previewUpdate(UpdateProposal(compilingInstructionsIn: snapshot.scope))
        }
        .disabled(!model.canModify)
      }
      ToolbarItem {
        if model.scope.kind == .project {
          Button("New Local Instructions…", systemImage: "plus") {
            model.beginCreation(.instructions)
          }
        }
      }
      ToolbarItem {
        Button("Choose Mapping Projects…") { model.chooseMappings() }
      }
      ToolbarItem {
        Button("Copy All Mappings") {
          copyText(snapshot.mappings.map(\.copyText).joined(separator: "\n\n"))
        }
      }
      ToolbarItem {
        Button("Add Instructions…") {
          model.beginDraft(.component)
          model.manifestDraft?.component.kind = .instructions
        }
      }
    }
  }
  private func orderedSections(_ sections: [String]) -> some View {
    ForEach(Array(sections.enumerated()), id: \.offset) { index, name in
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(index + 1, format: .number)
          .monospacedDigit().foregroundStyle(.secondary)
          .frame(minWidth: 24, alignment: .trailing)
        Text(name)
      }.accessibilityElement(children: .combine)
    }
  }

}
