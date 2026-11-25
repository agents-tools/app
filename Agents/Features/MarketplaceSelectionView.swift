import AgentsCore
import AgentsUpdates
import SwiftUI

struct MarketplaceSelectionView: View {
  @Binding var draft: MarketplacePackageDraft
  @Binding var errorText: String?
  let scope: InstallScope
  let resolve: () -> Void

  var body: some View {
    Form {
      Section(draft.package) {
        if draft.installed == nil { TextField("Dependency name", text: $draft.name) }
        PackageRequirementEditor(requirement: $draft.requirement)
        Button(draft.currentResolution ? "Resolve Again" : "Resolve Packages", action: resolve)
          .disabled(draft.name.isEmpty || (try? draft.requirement.canonicalized()) == nil)
      }
      if draft.currentResolution {
        Section("Installation") {
          Toggle("Resolve and Lock Only", isOn: $draft.pinOnly)
          if draft.pinOnly {
            Text(
              draft.installed != nil && !draft.selections.isEmpty
                ? "Applying clears this package’s client assignments. Switch off to keep editing them."
                : "Record the resolved releases without adding client assignments."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        ForEach(draft.reachableNodes, id: \.versions.node) { node in
          Section(node.versions.node.package) {
            MarketplaceVersionRows(versions: node.versions)
            LabeledContent("Marketplace") {
              CompactText(
                text: node.versions.node.catalog.origin.description
                  + (node.versions.node.catalog.subpath.map { " / " + $0 } ?? ""))
            }
            if !node.dependencies.isEmpty {
              LabeledContent(
                "Dependencies",
                value: node.dependencies.map(\.target.package)
                  .joined(separator: ", "))
            }
            if let members = node.availableMembers {
              let counts = Dictionary(grouping: members, by: \.marketplaceKey)
              ForEach(members, id: \.id) { member in
                if counts[member.marketplaceKey]?.count == 1 {
                  PackageClientPicker(
                    component: member, scope: scope, targets: binding(for: member, in: node)
                  )
                  .disabled(draft.pinOnly)
                } else {
                  LabeledContent(member.name, value: "Ambiguous member")
                    .foregroundStyle(.secondary)
                }
              }
            } else {
              Text("The archive is unavailable. Saved client selections can be retained.")
                .font(.caption).foregroundStyle(.secondary)
              ForEach(Array(draft.selections(in: node.versions.node).enumerated()), id: \.offset) {
                _, selection in
                LabeledContent(selection.member.name, value: clientNames(selection))
              }
            }
          }
        }
        let unavailable = draft.unavailableSelections(in: scope)
        if !unavailable.isEmpty {
          Section("Unavailable Selections") {
            ForEach(Array(unavailable.enumerated()), id: \.offset) { _, selection in
              let label = selection.package + " / " + selection.member.name
              LabeledContent(label, value: clientNames(selection))
              Button("Remove Unavailable Assignments", role: .destructive) {
                do {
                  try draft.removeUnavailableTargets(from: selection, in: scope)
                  errorText = nil
                } catch {
                  errorText = String(describing: error)
                }
              }.accessibilityHint(label)
            }
          }.disabled(draft.pinOnly)
        }
      }
    }.formStyle(.grouped)
  }

  private func clientNames(_ selection: MarketplaceMemberSelection) -> String {
    selection.targets.map(\.displayName).joined(separator: ", ")
  }

  private func binding(
    for member: BundleComponent, in node: MarketplaceResolutionNode
  ) -> Binding<Set<AgentID>> {
    Binding(
      get: { draft.targets(for: member.marketplaceKey, in: node.versions.node) },
      set: { targets in
        do {
          try draft.setTargets(targets, for: member.marketplaceKey, in: node)
          errorText = nil
        } catch {
          errorText = String(describing: error)
        }
      }
    )
  }
}

struct MarketplaceVersionRows: View {
  let versions: MarketplaceNodeVersions

  var body: some View {
    LabeledContent("Locked", value: versions.locked?.version ?? "None")
    LabeledContent("Eligible", value: versions.eligible.version)
    LabeledContent("Latest", value: versions.latest?.version ?? "Unavailable")
  }
}

struct PackageClientPicker: View {
  let component: BundleComponent
  let scope: InstallScope
  @Binding var targets: Set<AgentID>

  private var clients: [AgentID] { component.supportedTargets(in: scope) }
  private var selectedClients: [AgentID] { clients.filter(targets.contains) }

  var body: some View {
    LabeledContent {
      if clients.isEmpty {
        Text("No supported clients").foregroundStyle(.secondary)
      } else {
        Menu(
          selectedClients.isEmpty
            ? "Choose Clients"
            : selectedClients.map(\.displayName).joined(separator: ", ")
        ) {
          ForEach(clients, id: \.self) { client in
            Toggle(
              client.displayName,
              isOn: Binding(
                get: { targets.contains(client) },
                set: { if $0 { targets.insert(client) } else { targets.remove(client) } }
              ))
          }
        }
        .accessibilityLabel("Clients for " + component.name)
      }
    } label: {
      VStack(alignment: .leading) {
        Text(component.name)
        Text(DeclarationLabels.kind(component.kind.rawValue))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
