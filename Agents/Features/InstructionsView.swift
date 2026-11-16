import AppKit
import SwiftUI

struct InstructionsView: View {
  @Bindable var model: AppModel
  let snapshot: WorkspaceSnapshot

  var body: some View {
    List {
      Section("Declarations") {
        if snapshot.instructions.isEmpty {
          Text("No instruction components are declared.").foregroundStyle(.secondary)
        }
        ForEach(snapshot.instructions) { item in
          DisclosureGroup {
            RecordFields(record: item.record)
            Button("Inspect Declaration") { model.selectedItem = item.id }
          } label: {
            Label(item.container + " · Instructions", systemImage: "doc.text")
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
                LabeledContent("Location", value: item.authorFile.path)
                LabeledContent("Paths", value: item.paths.joined(separator: ", "))
                LabeledContent("Content hash", value: item.hash)
                Button("Open Author File") { NSWorkspace.shared.open(item.authorFile) }
              }
            }
          } else {
            Text("Local instructions are unavailable. See Diagnostics.").foregroundStyle(.secondary)
          }
        }
      }
      Section("Locked Target Mappings") {
        ForEach(snapshot.mappings) { mapping in
          DisclosureGroup {
            Text(mapping.status).foregroundStyle(.secondary)
            ForEach(mapping.targets) { target in
              DisclosureGroup(target.id) {
                LabeledContent("Agents", value: target.agents)
                if let imported = target.importedFile {
                  LabeledContent("Imports", value: imported)
                }
                ForEach(Array(target.sections.enumerated()), id: \.offset) { _, section in
                  Text(section)
                }
              }
            }
            if !mapping.unplaced.isEmpty {
              DisclosureGroup("Unplaced Sections") {
                ForEach(Array(mapping.unplaced.enumerated()), id: \.offset) { _, section in
                  Text(section)
                }
              }
            }
            ForEach(mapping.prompts.keys.sorted(), id: \.self) { name in
              DisclosureGroup("Named Prompt · " + name) {
                ForEach(Array((mapping.prompts[name] ?? []).enumerated()), id: \.offset) {
                  _, section in
                  Text(section)
                }
                Text("Prompt generation is unavailable in this build.")
                  .foregroundStyle(.secondary)
              }
            }
          } label: {
            Text(mapping.title)
          }
        }
      }
    }
    .textSelection(.enabled)
    .toolbar {
      ToolbarItem {
        Button("Edit Instructions…") { model.presentedIntent = .editStructure }
      }
    }
  }
}
