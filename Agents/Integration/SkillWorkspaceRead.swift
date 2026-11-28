import AgentsCore
import AgentsManifest
import AgentsUpdates
import Darwin
import Foundation

extension CoreReader {
  static func skillWorkspace(
    _ inspection: ScopeInspection, scope: WorkspaceScope, store: StateStore
  ) -> (items: [SkillWorkspaceItem], inventory: [InventoryItem], dependencies: [ReadDependency]) {
    let skills = inspection.components.filter { $0.kind == .skills }
    let byRecord = Dictionary(uniqueKeysWithValues: skills.map { ($0.record, $0) })
    let resources = Dictionary(uniqueKeysWithValues: inspection.resources.map { ($0.identity, $0) })
    let sources = Dictionary(uniqueKeysWithValues: inspection.sources.map { ($0.record, $0) })
    let declarations = SkillDeclarationOwner.collect(inspection, store: store)
    let bySource = Dictionary(grouping: declarations, by: \.source)
    let manifestRoot = scope.kind == .user ? store.directory : store.environment.projectDirectory
    let manifestSource = "local:" + manifestRoot.path
    let manifestPath = scope.kind == .user ? "agents.yaml" : ".agent/agents.yaml"
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
            mode: skill.skillInstallMode,
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
        guard matches.count == 1, let match = matches.first, !skill.occurrences.isEmpty,
          skill.occurrences.allSatisfy({
            $0.consumerEditable && $0.manifestPath == manifestPath
              && $0.declaringSource == manifestSource
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
      let owner = allOwned && matchedOwners.count == 1 ? matchedOwners.first : nil
      let modes = Set(records.compactMap(\.skillInstallMode))
      let liveSource: SkillSourceFile?
      if owner?.canEditInstallMode == true, owner?.effectiveMode == .edit, modes == [.edit],
        let resource = resource(first), resource.kind == LedgerResource.Kind.liveEdit.rawValue,
        records.allSatisfy({ $0.resources == [resource.identity] }),
        let source = sources[resource.sourceRecord], source.identity == first.source,
        source.kind == .local, source.container == nil, source.revision == "live",
        let root = source.location
      {
        liveSource = SkillSourceFile(root: root, resourcePath: resource.path)
      } else {
        liveSource = nil
      }
      return SkillWorkspaceItem(
        id: id, name: first.name,
        title: display.title ?? first.skillField("name") ?? first.name,
        summary: display.summary
          ?? records.lazy.compactMap { $0.skillField("description") }.first ?? "",
        scope: scope, source: first.source, sourceURL: display.sourceURL, iconURL: display.iconURL,
        iconRevision: display.iconRevision,
        recipients: AgentID.allCases.filter(recipients.contains), installations: rows,
        occurrences: records.flatMap(\.occurrences), componentRecords: Set(records.map(\.record)),
        isResolved: true, targetOwner: owner, resolvedModes: modes, liveSource: liveSource)
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
  let defaultMode: InstallMode
  let canEditInstallMode: Bool

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
      skillOverride: override?.override ?? .init(), inheritedMode: defaultMode,
      canEditInstallMode: canEditInstallMode)
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
          defaults: selection.agents ?? declaration.defaultAgents,
          defaultMode: selection.mode ?? .link,
          canEditInstallMode: declaredSource.kind == .local && declaredSource.requirement == nil)
      }
    }
    return owners(declaration.components, base: "/components", group: nil)
      + declaration.groups.enumerated().flatMap { index, group in
        owners(group.components, base: "/groups/\(index)/components", group: group.name)
      }
  }
}

struct SkillSourceFile: Equatable, Sendable {
  private let root: URL
  private let physicalRoot: String
  private let markdown: URL

  init?(root: URL, resourcePath: String) {
    let parts = resourcePath.split(separator: "/")
    guard root.isFileURL, !resourcePath.isEmpty, !resourcePath.hasPrefix("/"),
      !resourcePath.hasPrefix("~"), !resourcePath.contains("\\"), !resourcePath.contains("\0"),
      resourcePath == "." || parts.allSatisfy({ $0 != "." && $0 != ".." }),
      let physicalRoot = Self.realPath(root)
    else { return nil }
    self.root = root
    self.physicalRoot = physicalRoot
    let directory = resourcePath == "." ? root : root.appendingPathComponent(resourcePath)
    self.markdown = directory.appendingPathComponent("SKILL.md")
    guard fileURL() != nil else { return nil }
  }

  func fileURL() -> URL? {
    // Resolve again on open so a replaced symlink cannot redirect the editor outside the source.
    guard let currentRoot = Self.realPath(root), currentRoot.utf8.elementsEqual(physicalRoot.utf8),
      let path = Self.realPath(markdown),
      path.utf8.starts(with: (physicalRoot == "/" ? "/" : physicalRoot + "/").utf8)
    else { return nil }
    var info = stat()
    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
    return URL(fileURLWithPath: path)
  }

  private static func realPath(_ url: URL) -> String? {
    guard let path = realpath(url.path, nil) else { return nil }
    defer { free(path) }
    return String(cString: path)
  }
}

extension ComponentInspection {
  fileprivate var skillInstallMode: InstallMode? {
    skillField("mode").flatMap(InstallMode.init(rawValue:))
  }

  fileprivate func skillField(_ name: String) -> String? {
    guard case .object(let fields) = configuration, case .string(let value) = fields[name]
    else { return nil }
    return value
  }
}
