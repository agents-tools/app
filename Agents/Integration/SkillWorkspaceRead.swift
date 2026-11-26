import AgentsCore
import AgentsManifest
import AgentsUpdates
import Foundation

extension CoreReader {
  static func skillWorkspace(
    _ inspection: ScopeInspection, scope: WorkspaceScope, store: StateStore
  ) -> (items: [SkillWorkspaceItem], inventory: [InventoryItem], dependencies: [ReadDependency]) {
    let skills = inspection.components.filter { $0.kind == .skills }
    let byRecord = Dictionary(uniqueKeysWithValues: skills.map { ($0.record, $0) })
    let resources = Dictionary(uniqueKeysWithValues: inspection.resources.map { ($0.identity, $0) })
    let declarations = SkillDeclarationOwner.collect(inspection, store: store)
    let bySource = Dictionary(grouping: declarations, by: \.source)
    var inventory: [InventoryItem] = []
    var installations: [String: [InventoryItem]] = [:]
    var currentDestinations: [String: [URL]] = [:]
    for deployment in inspection.deployments {
      for record in deployment.ownerRecords {
        guard let skill = byRecord[record] else { continue }
        let recipients = Set(skill.recipients)
        let rows = deployment.recipients.filter(recipients.contains).map { agent in
          InventoryItem(
            id: .init(
              name: skill.name, agent: agent, scope: scope.installScope,
              path: deployment.location.path),
            status: deployment.status.rawValue,
            mode: skill.skillField("mode").flatMap(InstallMode.init(rawValue:)),
            source: skill.source, revision: skill.revision, version: skill.version)
        }
        inventory += rows
        installations[record, default: []] += rows
        if deployment.format == "agents/skill@1" && deployment.status == .current {
          currentDestinations[record, default: []].append(deployment.location)
        }
      }
    }

    func stableID(_ fields: [String]) -> String {
      ([scope.id] + fields).map { "\($0.utf8.count):\($0)" }.joined()
    }
    func resource(_ skill: ComponentInspection) -> ResourceInspection? {
      skill.resources.first.flatMap { resources[$0] }
    }
    let grouped = Dictionary(grouping: skills) { skill in
      // A resource path distinguishes same-name skills within a source. Records, modes and
      // declaration occurrences can change as a single skill is routed to more clients.
      stableID([skill.source, skill.name, resource(skill)?.path ?? skill.selection.identity])
    }
    var represented = Set<SkillDeclarationOwner.Key>()
    var metadata = SkillMetadataReader()
    var items: [SkillWorkspaceItem] = grouped.map { id, records in
      let first = records[0]
      var owners = Set<SkillDeclarationOwner.Key>()
      var matchedOwners: [SkillTargetOwner] = []
      var allOwned = true
      for skill in records {
        let matches = bySource[skill.source, default: []].compactMap { declaration in
          declaration.match(skill, resourcePath: resource(skill)?.path)
        }
        represented.formUnion(matches.map(\.key))
        let expectedPath = scope.kind == .user ? "agents.yaml" : ".agent/agents.yaml"
        guard matches.count == 1, let match = matches.first, !skill.occurrences.isEmpty,
          skill.occurrences.allSatisfy({
            $0.consumerEditable && $0.manifestPath == expectedPath
          })
        else {
          allOwned = false
          continue
        }
        if owners.insert(match.key).inserted { matchedOwners.append(match.owner) }
      }
      let locations =
        records.compactMap { resource($0)?.location }
        + records.flatMap { currentDestinations[$0.record] ?? [] }
      let display = metadata.read(locations)
      var seen = Set<InventoryItem.ID>()
      let rows = records.flatMap { installations[$0.record] ?? [] }
        .filter { seen.insert($0.id).inserted }
      let recipients = Set(records.flatMap(\.recipients))
      return SkillWorkspaceItem(
        id: id, name: first.name,
        title: display.title ?? first.skillField("name") ?? first.name,
        summary: display.summary
          ?? records.lazy.compactMap { $0.skillField("description") }.first ?? "",
        scope: scope, source: first.source, sourceURL: display.sourceURL, iconURL: display.iconURL,
        recipients: AgentID.allCases.filter(recipients.contains), installations: rows,
        occurrences: records.flatMap(\.occurrences), isResolved: true,
        targetOwner: allOwned && matchedOwners.count == 1 ? matchedOwners.first : nil)
    }

    // Explicit root selections can be browsed ahead of the first preparation. A group
    // definition alone does not establish that the scope uses it.
    let pending = declarations.filter { $0.group == nil }.flatMap { declaration in
      (declaration.names ?? []).compactMap { name -> SkillDeclarationOwner.Pending? in
        guard let owner = declaration.owner(named: name) else { return nil }
        guard !represented.contains(.init(node: owner.node, name: name)) else { return nil }
        return .init(name: name, source: declaration.source, root: declaration.root, owner: owner)
      }
    }
    let pendingGroups = Dictionary(grouping: pending) {
      stableID([$0.source, $0.name, $0.root, "declared"])
    }
    items += pendingGroups.map { id, declarations in
      let first = declarations[0]
      let recipients = Set(declarations.flatMap { $0.owner.requestedRecipients })
      return SkillWorkspaceItem(
        id: id, name: first.name, title: first.name, summary: "", scope: scope,
        source: first.source, sourceURL: nil, iconURL: nil,
        recipients: AgentID.allCases.filter(recipients.contains), installations: [],
        occurrences: [], isResolved: false,
        targetOwner: declarations.count == 1 ? first.owner : nil)
    }
    items.sort {
      let order = $0.title.localizedStandardCompare($1.title)
      return order == .orderedSame
        ? ($0.source, $0.id) < ($1.source, $1.id) : order == .orderedAscending
    }
    return (items, inventory, Array(metadata.dependencies))
  }
}

private struct SkillDeclarationOwner {
  struct Key: Hashable {
    let node: NodeID
    let name: String
  }

  struct Pending {
    let name: String
    let source: String
    let root: String
    let owner: SkillTargetOwner
  }

  let source: String
  let root: String
  let group: String?
  let names: Set<String>?
  let excluded: Set<String>
  let overrides: [String: [NamedSkillOverrideDeclaration]]
  let node: NodeID
  let pointer: String
  let digest: String
  let defaults: [AgentID]

  func match(_ skill: ComponentInspection, resourcePath: String?)
    -> (key: Key, owner: SkillTargetOwner)?
  {
    guard skill.group == group, skill.root == ".",
      root == "." || resourcePath == root || resourcePath?.hasPrefix(root + "/") == true
    else { return nil }
    let canonical = PathSafety.sanitizeName(skill.name)
    let selected: String
    if let names {
      let leaf = resourcePath.map { PathSafety.sanitizeName(($0 as NSString).lastPathComponent) }
      let matching = names.intersection([canonical, leaf].compactMap { $0 })
      guard matching.count == 1, let name = matching.first else { return nil }
      selected = name
    } else {
      guard !excluded.contains(canonical) else { return nil }
      selected = canonical
    }
    guard let owner = owner(named: selected) else { return nil }
    return (.init(node: node, name: selected), owner)
  }

  func owner(named name: String) -> SkillTargetOwner? {
    let entries = overrides[name, default: []]
    guard entries.count <= 1 else { return nil }
    let override = entries.first
    return SkillTargetOwner(
      documentDigest: digest, node: node, name: override?.name ?? name, declarationPointer: pointer,
      requestedRecipients: Set(override?.override.agents ?? defaults),
      mode: override?.override.mode)
  }

  static func collect(_ inspection: ScopeInspection, store: StateStore) -> [Self] {
    guard let document = inspection.document, let declaration = inspection.declaration else {
      return []
    }
    let packageRoot = store.scope == .user ? store.directory : store.environment.projectDirectory
    let sources = declaration.sources
    func owners(_ components: [ComponentDeclaration], base: String, group: String?) -> [Self] {
      components.enumerated().compactMap { index, component in
        let pointer = base + "/\(index)"
        guard case .skills(let alias, let selection) = component,
          let node = document.node(at: pointer), document.editability(of: node) == .direct
        else { return nil }
        let declaredSource =
          alias == "."
          ? SourceDeclaration(kind: .local, location: packageRoot.path) : sources[alias]
        guard let declaredSource,
          let source = try? declaredSource.identity(environment: store.environment)
        else { return nil }
        let root = [declaredSource.path, selection.path].compactMap { $0 }
          .flatMap { $0.replacingOccurrences(of: "\\", with: "/").split(separator: "/") }
          .filter { $0 != "." }.joined(separator: "/")
        let excluded = Set((selection.exclude ?? []).map(PathSafety.sanitizeName))
        let names: Set<String>?
        switch selection.select {
        case .all: names = nil
        case .names(let values):
          names = Set(values.map(PathSafety.sanitizeName)).subtracting(excluded)
        }
        return Self(
          source: source, root: root.isEmpty ? "." : root, group: group,
          names: names, excluded: excluded,
          overrides: Dictionary(
            grouping: selection.overrideDeclarations, by: { PathSafety.sanitizeName($0.name) }),
          node: node, pointer: pointer, digest: document.digest,
          defaults: selection.agents ?? declaration.defaultAgents)
      }
    }
    return owners(declaration.components, base: "/components", group: nil)
      + declaration.groups.enumerated().flatMap { index, group in
        owners(group.components, base: "/groups/\(index)/components", group: group.name)
      }
  }
}

extension ComponentInspection {
  fileprivate func skillField(_ name: String) -> String? {
    guard case .object(let fields) = configuration, case .string(let value) = fields[name]
    else { return nil }
    return value
  }
}
