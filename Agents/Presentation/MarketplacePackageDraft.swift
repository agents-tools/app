import AgentsCore
import AgentsUpdates
import Foundation

struct MarketplacePackageDraft: Sendable {
  enum Installed: Sendable {
    case graph(MarketplaceRoot)
    case legacy(MarketplacePin)
  }

  let catalog: MarketplaceOrigin
  let package: String
  let installed: Installed?
  var name: String
  var requirement: SourceRequirement
  var pinOnly = false
  private(set) var selections: [MarketplaceMemberSelection] = []
  private(set) var resolution: MarketplaceResolution?

  init(release: MarketplaceRelease, legacy: MarketplacePin? = nil) {
    catalog = release.origin
    package = release.coordinate.package
    installed = legacy.map(Installed.legacy)
    name = legacy?.dependency.name ?? package
    requirement = .exact(release.coordinate.version)
  }

  init(upgrading root: MarketplaceRoot, to version: String? = nil) {
    catalog = root.catalog
    package = root.package
    installed = .graph(root)
    name = root.name
    requirement = version.map(SourceRequirement.exact) ?? root.requirement
    selections = root.selections
    pinOnly = selections.isEmpty
  }

  var title: String { (installed == nil ? "Install " : "Update ") + name }

  private var root: MarketplaceResolvedRoot? {
    resolution?.roots.first { $0.intent.name == name }
  }

  var currentResolution: Bool {
    guard let root else { return false }
    return (try? requirement.canonicalized()) == root.intent.requirement
  }

  var reachableNodes: [MarketplaceResolutionNode] {
    guard let root, let resolution else { return [] }
    let byID = Dictionary(uniqueKeysWithValues: resolution.nodes.map { ($0.versions.node, $0) })
    var reachable: Set<MarketplaceNodeID> = []
    var pending = [root.node]
    while let node = pending.popLast() {
      if reachable.insert(node).inserted {
        pending.append(contentsOf: (byID[node]?.dependencies ?? []).map(\.target))
      }
    }
    let nodes = resolution.nodes.filter { reachable.contains($0.versions.node) }
    return nodes.filter { $0.versions.node == root.node }
      + nodes.filter { $0.versions.node != root.node }
  }

  func request(selections: [MarketplaceMemberSelection]? = nil) throws
    -> MarketplaceResolutionRequest
  {
    if installed != nil { return .upgrade(name, requirement: requirement, selections: selections) }
    return .install(
      try MarketplaceRoot(
        name: name, catalog: catalog, package: package, requirement: requirement,
        selections: selections ?? []))
  }

  mutating func capture(_ value: MarketplaceResolution) {
    if resolution == nil, case .legacy = installed,
      let root = value.roots.first(where: { $0.intent.name == name })
    {
      selections = root.intent.selections
      pinOnly = selections.isEmpty
    }
    resolution = value
  }

  func targets(
    for member: MarketplaceMemberKey, in node: MarketplaceNodeID
  ) -> Set<AgentID> {
    Set(selections.first { $0.member == member && matches($0, node) }?.targets ?? [])
  }

  func selections(in node: MarketplaceNodeID) -> [MarketplaceMemberSelection] {
    selections.filter { matches($0, node) }
  }

  mutating func setTargets(
    _ targets: Set<AgentID>, for member: MarketplaceMemberKey, in node: MarketplaceResolutionNode
  ) throws {
    let id = node.versions.node
    let existing = selections.firstIndex { $0.member == member && matches($0, id) }
    let catalog = id.catalog == root?.node.catalog ? nil : node.catalog
    if targets.isEmpty {
      if let existing { selections.remove(at: existing) }
      return
    }
    let selection = try MarketplaceMemberSelection(
      package: id.package, catalog: catalog, member: member, targets: Array(targets))
    if let existing {
      selections[existing] = selection
    } else {
      selections.append(selection)
    }
  }

  func unavailableSelections(in scope: InstallScope) -> [MarketplaceMemberSelection] {
    let nodes = reachableNodes
    return selections.filter { selection in
      guard let node = nodes.first(where: { matches(selection, $0.versions.node) }) else {
        return true
      }
      guard let members = node.availableMembers else { return false }
      let matches = members.filter { $0.marketplaceKey == selection.member }
      return matches.count != 1
        || !Set(selection.targets).isSubset(of: matches[0].supportedTargets(in: scope))
    }
  }

  mutating func removeUnavailableTargets(
    from selection: MarketplaceMemberSelection, in scope: InstallScope
  ) throws {
    guard let node = reachableNodes.first(where: { matches(selection, $0.versions.node) }),
      let members = node.availableMembers?.filter({ $0.marketplaceKey == selection.member }),
      members.count == 1
    else {
      selections.removeAll { $0 == selection }
      return
    }
    let retained = Set(selection.targets).intersection(members[0].supportedTargets(in: scope))
    try setTargets(retained, for: selection.member, in: node)
  }

  func canReview(in scope: InstallScope) -> Bool {
    currentResolution
      && (pinOnly || (!selections.isEmpty && unavailableSelections(in: scope).isEmpty))
  }

  func preview(scope: InstallScope, environment: RuntimeEnvironment, hostedAccess: HostedMarketplaceAccess? = nil) throws
    -> MarketplaceResolutionPreview
  {
    let candidate = try MarketplaceOperations.previewResolution(
      reviewedRequest(in: scope), scope: scope, environment: environment, hostedAccess: hostedAccess)
    try validate(candidate.resolution, graph: candidate.report.marketplaceGraphChange,
                 changes: candidate.report.marketplaceChanges)
    return candidate
  }

  func previewLock(scope: InstallScope, environment: RuntimeEnvironment, hostedAccess: HostedMarketplaceAccess? = nil) throws
    -> MarketplaceLockPreview
  {
    let candidate = try MarketplaceOperations.previewLockOnly(
      reviewedRequest(in: scope), scope: scope, environment: environment, hostedAccess: hostedAccess)
    try validate(candidate.resolution, graph: candidate.report.marketplaceGraphChange,
                 changes: candidate.report.marketplaceChanges)
    return candidate
  }

  private func reviewedRequest(in scope: InstallScope) throws -> MarketplaceResolutionRequest {
    guard canReview(in: scope) else {
      throw CoreError.invalidState("Resolve the package and review its client selections first.")
    }
    return try request(selections: pinOnly ? [] : selections)
  }

  private func validate(
    _ checked: MarketplaceResolution, graph: MarketplaceGraphUpdate?, changes: [MarketplacePackageUpdate]?
  ) throws {
    guard let resolution else { throw CoreError.invalidState("Resolve the package first.") }
    guard checked.nodes.map(\.versions) == resolution.nodes.map(\.versions),
      checked.nodes.map(\.dependencies) == resolution.nodes.map(\.dependencies),
      checked.nodes.map({ $0.availableMembers?.map(\.id) })
        == resolution.nodes.map({ $0.availableMembers?.map(\.id) }),
      checked.roots.filter({ $0.intent.name != name })
        == resolution.roots.filter({
          $0.intent.name != name
        })
    else {
      throw CoreError.invalidState("The resolved packages changed. Resolve them again for review.")
    }
    switch installed {
    case .graph(let original):
      guard
        graph.map({ change in
          change.before?.roots.contains(where: { $0.intent == original }) == true
        }) ?? true
      else {
        throw CoreError.invalidState(
          "The installed package changed. Reopen it from Installed Packages.")
      }
    case .legacy(let original):
      guard changes?.contains(where: { $0.before == original }) == true
      else {
        throw CoreError.invalidState(
          "The installed package changed. Reopen it from Installed Packages.")
      }
    case nil:
      // A new draft cannot replace a root that appeared under the same alias while it was open.
      guard
        graph?.before?.roots.contains(where: {
          $0.intent.name == name
        }) != true,
        changes?.contains(where: { $0.before?.dependency.name == name })
          != true
      else {
        throw CoreError.invalidState("That package alias is already installed.")
      }
    }
  }

  private func matches(_ selection: MarketplaceMemberSelection, _ node: MarketplaceNodeID) -> Bool {
    guard selection.package == node.package else { return false }
    guard let catalog = selection.catalog else { return root?.node.catalog == node.catalog }
    if let index = catalog.hostedIndex { return node.catalog.hostedIndex == index }
    return node.catalog.kind == .git && node.catalog.subpath == catalog.subpath
      && (try? SourceOrigin.git(catalog.location)) == node.catalog.origin
  }
}
