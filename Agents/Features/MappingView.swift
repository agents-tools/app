import SwiftUI

struct MappingView: View {
  @Bindable var model: AppModel
  var body: some View {
    if let session = model.mappingSession {
      VStack(alignment: .leading, spacing: 16) {
        Text("Instruction Mappings").font(.headline)
        switch session.stage {
        case .input:
          Form {
            Text("User configuration is included. Choose the projects to inspect.")
            ForEach(session.availableProjects, id: \.self) { url in
              Toggle(
                isOn: Binding(
                  get: { model.mappingSession?.selectedProjects.contains(url) ?? false },
                  set: {
                    if $0 {
                      model.mappingSession?.selectedProjects.append(url)
                    } else {
                      model.mappingSession?.selectedProjects.removeAll { $0 == url }
                    }
                  })
              ) { PathView(url: url) }
            }
          }.formStyle(.grouped)
          Button("Read Mappings") { model.readMappings() }.keyboardShortcut(.defaultAction)
        case .loading:
          HStack {
            ProgressView().controlSize(.small)
            Text("Reading instruction mappings for the selected scopes…")
          }
        case .loaded(let mappings):
          List {
            ForEach(mappings) { mapping in
              Section(mapping.title) {
                Text(mapping.status).foregroundStyle(.secondary)
                PathView(url: mapping.scope.root, scope: mapping.scope)
                ForEach(mapping.targets) { target in
                  DisclosureGroup(target.id) {
                    LabeledContent("Agents", value: target.agents)
                    if let imported = target.importedFile {
                      LabeledContent("Imports", value: imported)
                    }
                    ForEach(Array(target.sections.enumerated()), id: \.offset) { _, section in
                      Text(section.qualifiedName)
                    }
                  }
                }
                if !mapping.unplaced.isEmpty {
                  DisclosureGroup("Unplaced Sections") {
                    ForEach(Array(mapping.unplaced.enumerated()), id: \.offset) { _, section in
                      Text(section.qualifiedName)
                    }
                  }
                }
                ForEach(mapping.prompts.keys.sorted(), id: \.self) { name in
                  DisclosureGroup("Prompt · " + name) {
                    ForEach(Array((mapping.prompts[name] ?? []).enumerated()), id: \.offset) {
                      _, section in Text(section.qualifiedName)
                    }
                  }
                }
                Button("Copy This Mapping") { copyText(mapping.copyText) }
              }
            }
          }.textSelection(.enabled)
          Button("Copy All Mappings") {
            copyText(mappings.map(\.copyText).joined(separator: "\n\n"))
          }
          Text("Scopes are read individually. Missing or unavailable state is included above.")
            .font(.caption).foregroundStyle(.secondary)
        case .outdated:
          Text("The selection changed. Read the mappings again for the current selection.")
        case .cancelled: Text("The mapping read was cancelled before it started.")
        }
        HStack {
          Spacer()
          Button("Done") { model.mappingSession = nil }.keyboardShortcut(.cancelAction)
        }
      }
      .padding(24)
      .frame(width: 600, height: sheetHeight(session))
    }
  }

  private func sheetHeight(_ session: MappingSession) -> CGFloat? {
    switch session.stage {
    case .input, .loaded: 560
    default: nil
    }
  }
}
