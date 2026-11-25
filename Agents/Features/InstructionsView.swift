import AgentsUpdates
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
      let rules = snapshot.inspection.deployments.filter { $0.format == "agents/antigravity-rule@1" }
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
      Section("Locked Target Mappings") {
        ForEach(snapshot.mappings) { mapping in
          DisclosureGroup {
            Text(mapping.status).foregroundStyle(.secondary)
            Button("Copy Mapping") { copyText(mapping.copyText) }
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
                Button("Generate Preview…") { model.previewPrompt(name: name, in: mapping.scope) }
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
        Button("Review Compilation…") {
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
}
