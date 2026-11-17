import AgentsCore
import SwiftUI

struct SourceStateView: View {
  let snapshot: WorkspaceSnapshot
  let model: AppModel

  var body: some View {
    Form {
      Section("Recorded Source State") {
        Button("Import Configuration…") { model.beginImport() }
        Button("Subscribe to Source…") { model.beginWatch() }
        ForEach(snapshot.inspection.sources, id: \.record) { source in
          DetailsGroup(source.identity) {
            LabeledContent("Kind", value: DeclarationLabels.kind(source.kind.rawValue))
            LabeledContent("Revision") { CompactText(text: source.revision) }
            if let version = source.version { LabeledContent("Version", value: version) }
            if let location = source.location {
              LabeledContent("Location") { PathView(url: location, scope: snapshot.scope) }
            }
          }
        }
        if snapshot.inspection.sources.isEmpty {
          Text("No sources recorded in resolved state.").foregroundStyle(.secondary)
        }
      }
      Section("Subscription Baselines") {
        if let watch = snapshot.watch {
          ForEach(watch.sources.keys.sorted(), id: \.self) { id in
            if let state = watch.sources[id] {
              DetailsGroup(id) {
                switch state.seen {
                case .revision(let revision): LabeledContent("Seen revision", value: revision)
                case .artifacts(let artifacts):
                  ForEach(artifacts.keys.sorted(), id: \.self) { name in
                    LabeledContent(name, value: artifacts[name] ?? "")
                  }
                }
              }
            }
          }
          ForEach(snapshot.inspection.declaration?.watch ?? [], id: \.self) { alias in
            Button("Unsubscribe “" + alias + "”…") {
              model.beginWatch(source: alias, removing: true)
            }
          }
          if watch.sources.isEmpty {
            Text("No subscription baselines recorded.").foregroundStyle(.secondary)
          }
        } else {
          Text("Subscription baselines are unavailable. See Diagnostics.").foregroundStyle(
            .secondary)
        }
        Text("Recorded baselines do not indicate whether a source has newer content.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}
