import AgentsCore
import SwiftUI

struct SourceStateView: View {
  let snapshot: WorkspaceSnapshot

  var body: some View {
    Form {
      Section("Recorded Source State") {
        if let resolved = snapshot.resolved {
          ForEach(resolved.sources.keys.sorted(), id: \.self) { id in
            if let source = resolved.sources[id] {
              DisclosureGroup(id) {
                LabeledContent("Kind", value: source.kind.rawValue)
                if let location = source.url { LabeledContent("Location", value: location) }
                if let path = source.path { LabeledContent("Search path", value: path) }
                if let requirement = source.requirement {
                  DeclarationField(name: "Requirement", value: .requirement(requirement))
                }
              }
            }
          }
          if resolved.sources.isEmpty {
            Text("No sources recorded in resolved state.").foregroundStyle(.secondary)
          }
        } else {
          Text("Resolved source state is unavailable. See Diagnostics.").foregroundStyle(.secondary)
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
