import AgentsCore
import SwiftUI

struct SourceStateView: View {
  let snapshot: WorkspaceSnapshot

  var body: some View {
    Form {
      Section("Recorded Source State") {
        ForEach(snapshot.inspection.sources, id: \.record) { source in
          DisclosureGroup {
            LabeledContent("Kind", value: DeclarationLabels.kind(source.kind.rawValue))
            LabeledContent("Revision") { CompactText(text: source.revision) }
            if let version = source.version { LabeledContent("Version", value: version) }
            if let location = source.location {
              LabeledContent("Location") { PathView(url: location, scope: snapshot.scope) }
            }
          } label: {
            Text(source.identity).lineLimit(1).truncationMode(.middle).help(source.identity)
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
              DisclosureGroup(id) {
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
    .textSelection(.enabled)
  }
}
