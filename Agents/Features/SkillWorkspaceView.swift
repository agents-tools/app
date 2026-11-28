import AgentsCore
import AppKit
import SwiftUI

struct SkillWorkspaceView: View {
  @Bindable var model: AppModel
  let snapshot: WorkspaceSnapshot

  var body: some View {
    SkillGallery(
      items: visibleSkills, scope: snapshot.scope,
      selection: Binding(
        get: { model.selectedSkillID },
        set: { id in
          model.selectedSkillID = id
          if id != nil, !model.preferences.inspectorVisible { model.setInspectorVisible(true) }
        })
    )
    .toolbar {
      ToolbarItem {
        Menu {
          Button("New Local Skill…") { model.beginCreation(.skill) }
          Button("Add from Source…") { model.beginCatalog() }
        } label: {
          Label("Add Skill", systemImage: "plus")
        }
        .disabled(!model.canModify)
      }
    }
  }

  private var visibleSkills: [SkillWorkspaceItem] {
    guard let client = model.clientFilter else { return snapshot.skillWorkspaceItems }
    return snapshot.skillWorkspaceItems.filter { $0.isUsed(by: client, in: snapshot.scope) }
  }
}

struct SkillWorkspaceInspector: View {
  private struct Edit: Identifiable {
    let item: SkillWorkspaceItem
    let field: SkillTargetsSheet.Field

    var id: String { item.id }
  }

  let model: AppModel
  let snapshot: WorkspaceSnapshot
  @State private var edit: Edit?
  @State private var sourceOpenFailed = false

  var body: some View {
    Group {
      if let id = model.selectedSkillID,
        let item = snapshot.skillWorkspaceItems.first(where: { $0.id == id }),
        model.clientFilter.map({ item.isUsed(by: $0, in: snapshot.scope) }) ?? true
      {
        let component = snapshot.inspection.components.first {
          item.componentRecords.contains($0.record)
        }
        SkillDetails(
          item: item,
          openClient: { client in
            if item.scope != snapshot.scope { model.select(item.scope) }
            model.showClientOverview(client)
          },
          assistance: model.assistanceAvailable && item.scope == snapshot.scope
            && component.flatMap({ AssistanceInput.skill($0, action: .explainSkill) }) != nil
            ? { action in
              if let component, let input = AssistanceInput.skill(component, action: action) {
                model.reviewAssistance(input)
              }
            } : nil,
          editTargets: item.scope == snapshot.scope && item.canEditTargets && model.canModify
            ? { edit = Edit(item: item, field: .targets) } : nil,
          changeInstallMode: item.scope == snapshot.scope && item.canEditInstallMode
            && model.canPreviewSkillChanges
            ? { edit = Edit(item: item, field: .mode) } : nil,
          openSource: item.scope == snapshot.scope && item.liveSource != nil && !model.readsStale
            ? { openSource(for: item) } : nil,
          openOwner: item.scope != snapshot.scope
            ? {
              model.select(item.scope)
              model.selectedSkillID = item.id
            } : nil
        )
      } else {
        ContentUnavailableView("Select a Skill", systemImage: "square.stack.3d.up")
      }
    }
    .sheet(item: $edit) { edit in
      SkillTargetsSheet(model: model, item: edit.item, field: edit.field)
    }
    .alert("Couldn’t Open Source SKILL.md", isPresented: $sourceOpenFailed) {
      Button("OK", role: .cancel) {}
    }
  }

  private func openSource(for item: SkillWorkspaceItem) {
    guard let url = model.currentSkillSourceURL(for: item), NSWorkspace.shared.open(url) else {
      sourceOpenFailed = true
      return
    }
  }
}
