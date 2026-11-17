import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    TabView {
      Form {
        Section("Projects") {
          if model.preferences.projects.isEmpty {
            Text("No project directories added.").foregroundStyle(.secondary)
          }
          ForEach(model.preferences.projects, id: \.self) { url in
            LabeledContent(url.lastPathComponent) {
              Button("Remove") { model.removeProject(url) }.disabled(
                model.isApplying || model.isTerminating)
            }
            PathView(url: url).font(.caption).foregroundStyle(.secondary)
          }
          Button("Add Project…") { chooseProject(for: model) }.disabled(
            model.isApplying || model.isTerminating)
          Text("Adding and removing directories only changes the app’s project list.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section("Appearance") {
          Toggle("Show inspector", isOn: Bindable(model.preferences).inspectorVisible)
        }
      }
      .formStyle(.grouped)
      .tabItem { Label("General", systemImage: "gearshape") }

      ClientSettingsView(model: model)
        .tabItem { Label("Agent Clients", systemImage: "desktopcomputer") }

      Form {
        Section("On-device Assistance") {
          Toggle(
            "Allow on-device assistance",
            isOn: Binding(
              get: { model.preferences.assistanceEnabled }, set: { model.setAssistanceEnabled($0) })
          )
          Text(AssistanceAvailability.status)
          Text(
            model.preferences.assistanceEnabled
              ? "Selected skill explanations, description translation and change explanations use only reviewed content on this Mac. Generated text never applies changes."
              : "On-device assistance is turned off."
          )
          .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      .tabItem { Label("Assistance", systemImage: "sparkles") }
    }
    .padding(16)
  }
}
