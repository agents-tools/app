import AgentsCore
import AgentsUpdates
import SwiftUI

struct MarketplaceGraphReview: View {
  let change: MarketplaceGraphUpdate

  var body: some View {
    Section("Package Changes") {
      if !change.affectedRoots.isEmpty {
        LabeledContent("Affected packages", value: change.affectedRoots.joined(separator: ", "))
      }

      let beforeRoots = change.before?.roots ?? []
      let afterRoots = change.after?.roots ?? []
      let names = Set(beforeRoots.map(\.intent.name)).union(afterRoots.map(\.intent.name)).sorted()
      ForEach(names, id: \.self) { name in
        let before = beforeRoots.first { $0.intent.name == name }?.intent
        let after = afterRoots.first { $0.intent.name == name }?.intent
        if before != after {
          DisclosureGroup("Package intent · " + name) {
            rootChanges(before: before, after: after)
          }
        }
      }

      let beforeNodes = change.before?.nodes ?? []
      let afterNodes = change.after?.nodes ?? []
      let ids =
        afterNodes.map(\.id)
        + beforeNodes.map(\.id).filter { id in !afterNodes.contains { $0.id == id } }
      ForEach(ids, id: \.self) { id in
        let before = beforeNodes.first { $0.id == id }
        let after = afterNodes.first { $0.id == id }
        if before != after {
          DisclosureGroup(nodeTitle(id, before: before, after: after)) {
            CompactText(text: id.description)
            if let before { nodeRelease("Locked", before) }
            if let after { nodeRelease("Proposed", after) }
            memberChanges(before: before?.members ?? [], after: after?.members ?? [])
          }
        }
      }
    }
  }

  @ViewBuilder private func rootChanges(before: MarketplaceRoot?, after: MarketplaceRoot?)
    -> some View
  {
    if before?.requirement != after?.requirement {
      if let before {
        LabeledContent(
          "Previous requirement", value: DeclarationLabels.requirement(before.requirement))
      }
      if let after {
        LabeledContent(
          "Proposed requirement", value: DeclarationLabels.requirement(after.requirement))
      }
    }
    let old = before?.selections ?? []
    let new = after?.selections ?? []
    ForEach(Array(old.filter { !new.contains($0) }.enumerated()), id: \.offset) { _, selection in
      selectionRow("Remove selection", selection)
    }
    ForEach(Array(new.filter { !old.contains($0) }.enumerated()), id: \.offset) { _, selection in
      selectionRow("Add selection", selection)
    }
  }

  private func selectionRow(_ title: LocalizedStringKey, _ selection: MarketplaceMemberSelection)
    -> some View
  {
    LabeledContent(title) {
      VStack(alignment: .trailing) {
        Text(selection.package + " / " + selection.member.name)
        Text(DeclarationLabels.kind(selection.member.kind.rawValue))
          .foregroundStyle(.secondary)
        if let catalog = selection.catalog { CompactText(text: catalog.location) }
        Text(selection.targets.map(\.displayName).joined(separator: ", "))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func nodeTitle(
    _ id: MarketplaceNodeID, before: MarketplaceResolvedNode?, after: MarketplaceResolvedNode?
  ) -> String {
    switch (before?.coordinate.version, after?.coordinate.version) {
    case (nil, let version?): "Lock " + id.package + " " + version
    case (let version?, nil): "Unlock " + id.package + " " + version
    case (let old?, let new?) where old != new: id.package + " · " + old + " → " + new
    default: id.package
    }
  }

  private func nodeRelease(_ title: LocalizedStringKey, _ node: MarketplaceResolvedNode)
    -> some View
  {
    LabeledContent(title) {
      VStack(alignment: .trailing) {
        Text(node.coordinate.version).monospacedDigit()
        CompactText(text: node.archiveDigest).font(.caption.monospaced())
        if let commit = node.catalogCommit { CompactText(text: commit).font(.caption.monospaced()) }
        ForEach(Array(node.dependencies.enumerated()), id: \.offset) { _, edge in
          Text(
            edge.target.package + " · "
              + DeclarationLabels.requirement(edge.requirement.requirement)
          )
          .foregroundStyle(.secondary)
          .help(edge.target.description)
        }
      }
    }
  }

  @ViewBuilder private func memberChanges(
    before: [MarketplaceResolvedMember], after: [MarketplaceResolvedMember]
  ) -> some View {
    let old = Dictionary(uniqueKeysWithValues: before.map { ($0.key, $0.targets) })
    let new = Dictionary(uniqueKeysWithValues: after.map { ($0.key, $0.targets) })
    let keys = after.map(\.key) + before.map(\.key).filter { new[$0] == nil }
    ForEach(keys, id: \.self) { key in
      if old[key] != new[key] {
        LabeledContent(key.name, value: clients(old[key]) + " → " + clients(new[key]))
      }
    }
  }

  private func clients(_ targets: [AgentID]?) -> String {
    targets?.map(\.displayName).joined(separator: ", ") ?? "None"
  }
}
