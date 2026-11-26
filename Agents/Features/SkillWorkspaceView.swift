import AgentsCore
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
    return snapshot.skillWorkspaceItems.filter { $0.scope == snapshot.scope && $0.recipients.contains(client) }
  }
}

struct SkillWorkspaceInspector: View {
  let model: AppModel
  let snapshot: WorkspaceSnapshot
  @State private var editingItem: SkillWorkspaceItem?

  var body: some View {
    Group {
      if let id = model.selectedSkillID,
        let item = snapshot.skillWorkspaceItems.first(where: { $0.id == id }),
        model.clientFilter.map({ item.recipients.contains($0) }) ?? true
      {
        SkillDetails(
          item: item,
          openClient: { client in
            if item.scope != snapshot.scope { model.select(item.scope) }
            model.showClientOverview(client)
          },
          editTargets: item.scope == snapshot.scope && item.canEditTargets && model.canModify
            ? { editingItem = item } : nil,
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
    .sheet(item: $editingItem) { item in
      SkillTargetsSheet(model: model, item: item)
    }
  }
}
