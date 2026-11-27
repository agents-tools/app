import AgentsCore
import AppKit
import ImageIO
import SwiftUI

struct ClientFilterPicker: View {
  @Binding var selection: AgentID?

  var body: some View {
    Picker("View", selection: $selection) {
      Text("All Clients")
        .tag(AgentID?.none)
      Divider()
      ForEach(AgentID.allCases, id: \.self) { agent in
        Text(agent.displayName)
          .tag(Optional(agent))
      }
    }
    .pickerStyle(.menu)
    .accessibilityLabel("View")
    .help("Filter configuration by client")
  }
}

struct SkillGallery: View {
  let items: [SkillWorkspaceItem]
  let scope: WorkspaceScope
  @Binding var selection: String?

  var body: some View {
    SkillGalleryContent(
      items: items,
      scope: scope,
      selection: $selection
    )
  }
}

struct SkillDetails: View {
  let item: SkillWorkspaceItem
  let openClient: (AgentID) -> Void
  var assistance: ((AssistanceInput.Action) -> Void)? = nil
  var editTargets: (() -> Void)? = nil
  var changeInstallMode: (() -> Void)? = nil
  var openSource: (() -> Void)? = nil
  var openOwner: (() -> Void)? = nil

  var body: some View {
    SkillDetailsContent(
      item: item,
      openClient: openClient,
      assistance: assistance,
      editTargets: editTargets,
      changeInstallMode: changeInstallMode,
      openSource: openSource,
      openOwner: openOwner
    )
  }
}

struct SkillIconView: View {
  let url: URL?
  let revision: String?
  var size: CGFloat = 32

  var body: some View {
    SkillIconContent(url: url, revision: revision, size: size)
  }
}

// MARK: - Skill Gallery Content

private struct SkillGalleryContent: View {
  private enum DisplayMode: String, CaseIterable, Identifiable {
    case gallery
    case table

    var id: String { rawValue }
  }

  private struct GallerySection: Identifiable {
    let id: String
    let title: String
    let items: [SkillWorkspaceItem]
  }

  let items: [SkillWorkspaceItem]
  let scope: WorkspaceScope
  @Binding var selection: String?

  @State private var displayMode: DisplayMode = .gallery
  @State private var searchText: String = ""
  @State private var galleryWidth: CGFloat = 0
  @State private var sortOrder: [KeyPathComparator<SkillWorkspaceItem>] = [
    KeyPathComparator(\.title, order: .forward)
  ]
  @FocusState private var focusedCardID: String?

  private static let cardMinWidth: CGFloat = 220
  private static let cardMaxWidth: CGFloat = 360
  private static let gridSpacing: CGFloat = 12
  private static let galleryPadding: CGFloat = 16

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filteredItems: [SkillWorkspaceItem] {
    let query = trimmedSearch
    guard !query.isEmpty else { return items }
    return items.filter { item in
      item.title.localizedCaseInsensitiveContains(query)
        || item.summary.localizedCaseInsensitiveContains(query)
        || item.source.localizedCaseInsensitiveContains(query)
        || scopeDisplayName(for: item.scope).localizedCaseInsensitiveContains(query)
        || item.recipients.contains { $0.displayName.localizedCaseInsensitiveContains(query) }
        || item.installations.contains {
          $0.id.name.localizedCaseInsensitiveContains(query)
            || $0.id.agent.displayName.localizedCaseInsensitiveContains(query)
        }
    }
  }

  private var visibleItemIDs: [String] {
    filteredItems.map(\.id)
  }

  private var sortedTableItems: [SkillWorkspaceItem] {
    filteredItems.sorted(using: sortOrder)
  }

  private var gallerySections: [GallerySection] {
    var currentScopeItems: [SkillWorkspaceItem] = []
    var userConfigurationItems: [SkillWorkspaceItem] = []
    var otherScopeOrder: [String] = []
    var otherScopeTitles: [String: String] = [:]
    var otherScopeItems: [String: [SkillWorkspaceItem]] = [:]

    for item in filteredItems {
      if item.scope.id == scope.id {
        currentScopeItems.append(item)
      } else if item.scope.kind == .user {
        userConfigurationItems.append(item)
      } else {
        if otherScopeItems[item.scope.id] == nil {
          otherScopeOrder.append(item.scope.id)
          otherScopeTitles[item.scope.id] = scopeDisplayName(for: item.scope)
        }
        otherScopeItems[item.scope.id, default: []].append(item)
      }
    }

    var sections: [GallerySection] = []
    if !currentScopeItems.isEmpty {
      sections.append(
        GallerySection(
          id: scope.id,
          title: scopeDisplayName(for: scope),
          items: currentScopeItems
        )
      )
    }
    if !userConfigurationItems.isEmpty {
      sections.append(
        GallerySection(
          id: "scope.user.configuration",
          title: "User Configuration",
          items: userConfigurationItems
        )
      )
    }
    for scopeID in otherScopeOrder {
      guard let scopedItems = otherScopeItems[scopeID], !scopedItems.isEmpty else { continue }
      sections.append(
        GallerySection(
          id: scopeID,
          title: otherScopeTitles[scopeID] ?? scopeID,
          items: scopedItems
        )
      )
    }
    return sections
  }

  private var orderedGalleryIDs: [String] {
    gallerySections.flatMap { $0.items.map(\.id) }
  }

  private var estimatedColumnCount: Int {
    let usableWidth = max(0, galleryWidth - (Self.galleryPadding * 2))
    let count = Int((usableWidth + Self.gridSpacing) / (Self.cardMinWidth + Self.gridSpacing))
    return max(1, count)
  }

  private var gridColumns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: Self.cardMinWidth, maximum: Self.cardMaxWidth),
        spacing: Self.gridSpacing,
        alignment: .top
      )
    ]
  }

  private var itemCountSummary: String {
    let unit = items.count == 1 ? "skill" : "skills"
    if trimmedSearch.isEmpty {
      return "\(items.count) \(unit)"
    }
    return "\(filteredItems.count) of \(items.count) \(unit)"
  }

  private var navigationSubtitle: String {
    guard !scope.title.isEmpty else { return itemCountSummary }
    return "\(scope.title) · \(itemCountSummary)"
  }

  var body: some View {
    contentView
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      .navigationSubtitle(navigationSubtitle)
      .searchable(
        text: $searchText,
        placement: .toolbar,
        prompt: "Filter skills"
      )
      .toolbar {
        ToolbarItem(placement: .automatic) {
          Picker("Display Mode", selection: $displayMode) {
            Label("Gallery", systemImage: "square.grid.2x2")
              .labelStyle(.iconOnly)
              .accessibilityLabel("Gallery")
              .help("Gallery")
              .tag(DisplayMode.gallery)
            Label("Table", systemImage: "list.bullet")
              .labelStyle(.iconOnly)
              .accessibilityLabel("Table")
              .help("Table")
              .tag(DisplayMode.table)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .accessibilityLabel("Display Mode")
        }
      }
      .onAppear {
        reconcileSelection(validIDs: visibleItemIDs)
      }
      .onChange(of: visibleItemIDs) { _, newIDs in
        reconcileSelection(validIDs: newIDs)
      }
      .onChange(of: selection) { _, newSelection in
        guard let newSelection else { return }
        if !visibleItemIDs.contains(newSelection) {
          selection = nil
        }
      }
  }

  @ViewBuilder
  private var contentView: some View {
    if items.isEmpty {
      ContentUnavailableView(
        "No Skills",
        systemImage: "square.stack.3d.up",
        description: Text("No skills match the current view.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if filteredItems.isEmpty {
      ContentUnavailableView {
        Label("No Matching Skills", systemImage: "magnifyingglass")
      } description: {
        Text("No skills match \"\(trimmedSearch)\".")
      } actions: {
        Button("Clear Search") {
          searchText = ""
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      switch displayMode {
      case .gallery:
        galleryView
      case .table:
        tableView
      }
    }
  }

  private var galleryView: some View {
    ScrollViewReader { scrollProxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          ForEach(gallerySections) { section in
            VStack(alignment: .leading, spacing: 10) {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(section.title)
                  .font(.subheadline.weight(.semibold))
                  .foregroundStyle(.secondary)
                Text("\(section.items.count)")
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .monospacedDigit()
              }

              LazyVGrid(
                columns: gridColumns,
                alignment: .leading,
                spacing: Self.gridSpacing
              ) {
                ForEach(section.items) { item in
                  SkillCardView(
                    item: item,
                    isSelected: selection == item.id,
                    clientsSummary: item.isResolved ? formattedClients(for: item.recipients) : "Pending installation"
                  ) {
                    selection = item.id
                    focusedCardID = item.id
                  }
                  .id(item.id)
                  .focused($focusedCardID, equals: item.id)
                }
              }
            }
          }
        }
        .padding(Self.galleryPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.gallery")
      }
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { newWidth in
        galleryWidth = newWidth
      }
      .onMoveCommand { direction in
        moveGallerySelection(direction, scrollProxy: scrollProxy)
      }
      .onAppear {
        if let selection {
          scrollProxy.scrollTo(selection)
        }
      }
    }
  }

  private var tableView: some View {
    Table(sortedTableItems, selection: $selection, sortOrder: $sortOrder) {
      TableColumn("Name", value: \.title) { item in
        HStack(spacing: 8) {
          SkillIconView(url: item.iconURL, revision: item.iconRevision, size: 20)
          VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
              .font(.body)
              .lineLimit(1)
            let trimmedSummary = item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSummary.isEmpty {
              Text(trimmedSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
        .padding(.vertical, 2)
      }
      .width(min: 180, ideal: 260)

      TableColumn("Scope", value: \.scope.title) { item in
        Text(scopeDisplayName(for: item.scope))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .width(min: 120, ideal: 160)

      TableColumn("Clients") { item in
        Text(item.isResolved ? formattedClients(for: item.recipients) : "Pending installation")
          .foregroundStyle(item.recipients.isEmpty ? .tertiary : .secondary)
          .lineLimit(1)
      }
      .width(min: 120, ideal: 200)
    }
    .accessibilityIdentifier("skills.table")
  }

  private func moveGallerySelection(_ direction: MoveCommandDirection, scrollProxy: ScrollViewProxy)
  {
    let ids = orderedGalleryIDs
    guard !ids.isEmpty else { return }

    let anchorID = selection ?? focusedCardID
    let nextIndex: Int
    if let anchorID, let currentIndex = ids.firstIndex(of: anchorID) {
      switch direction {
      case .left:
        nextIndex = max(0, currentIndex - 1)
      case .right:
        nextIndex = min(ids.count - 1, currentIndex + 1)
      case .up:
        nextIndex = max(0, currentIndex - estimatedColumnCount)
      case .down:
        nextIndex = min(ids.count - 1, currentIndex + estimatedColumnCount)
      @unknown default:
        return
      }
    } else {
      switch direction {
      case .left, .up:
        nextIndex = ids.count - 1
      case .right, .down:
        nextIndex = 0
      @unknown default:
        return
      }
    }

    let targetID = ids[nextIndex]
    selection = targetID
    focusedCardID = targetID
    scrollProxy.scrollTo(targetID)
  }

  private func reconcileSelection(validIDs: [String]) {
    guard let currentSelection = selection else { return }
    if !validIDs.contains(currentSelection) {
      selection = nil
      if focusedCardID == currentSelection {
        focusedCardID = nil
      }
    }
  }

  private func scopeDisplayName(for targetScope: WorkspaceScope) -> String {
    let trimmed = targetScope.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if targetScope.kind == .user {
      return trimmed.isEmpty ? "User Configuration" : trimmed
    }
    return trimmed.isEmpty ? "Workspace" : trimmed
  }

  private func formattedClients(for recipients: [AgentID]) -> String {
    var seen: Set<AgentID> = []
    var names: [String] = []
    for agent in recipients where seen.insert(agent).inserted {
      names.append(agent.displayName)
    }
    guard !names.isEmpty else { return "No clients" }
    if names.count <= 3 {
      return names.joined(separator: ", ")
    }
    let leading = names.prefix(2).joined(separator: ", ")
    return "\(leading) +\(names.count - 2)"
  }
}

private struct SkillCardView: View {
  let item: SkillWorkspaceItem
  let isSelected: Bool
  let clientsSummary: String
  let select: () -> Void

  @State private var isHovered = false
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  private var trimmedSummary: String {
    item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    Button(action: select) {
      HStack(alignment: .top, spacing: 10) {
        SkillIconView(url: item.iconURL, revision: item.iconRevision, size: 32)

        VStack(alignment: .leading, spacing: 4) {
          Text(item.title)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)

          if !trimmedSummary.isEmpty {
            Text(trimmedSummary)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .truncationMode(.tail)
              .fixedSize(horizontal: false, vertical: true)
          }

          Spacer(minLength: 2)

          Text(clientsSummary)
            .font(.caption)
            .foregroundStyle(item.recipients.isEmpty ? .tertiary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: 86, maxHeight: .infinity, alignment: .topLeading)
      .background(cardBackground)
      .overlay(cardBorder)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(SkillCardButtonStyle())
    .onHover { hovering in
      isHovered = hovering
    }
    .accessibilityIdentifier("skill.card.\(item.id)")
    .accessibilityLabel(accessibilityLabelText)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var cardBackground: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return ZStack {
      shape.fill(Color(nsColor: .controlBackgroundColor))
      if isSelected {
        shape.fill(Color.accentColor.opacity(reduceTransparency ? 0.2 : 0.12))
      } else if isHovered {
        shape.fill(Color.primary.opacity(reduceTransparency ? 0.06 : 0.035))
      }
    }
  }

  private var cardBorder: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    let strokeColor: Color =
      if isSelected {
        .accentColor
      } else if colorSchemeContrast == .increased {
        Color.primary.opacity(0.45)
      } else {
        Color(nsColor: .separatorColor)
      }
    let lineWidth: CGFloat = isSelected ? (colorSchemeContrast == .increased ? 2 : 1.5) : 1
    return shape.strokeBorder(strokeColor, lineWidth: lineWidth)
  }

  private var accessibilityLabelText: String {
    var parts = [item.title]
    if !trimmedSummary.isEmpty {
      parts.append(trimmedSummary)
    }
    parts.append(clientsSummary)
    return parts.joined(separator: ", ")
  }
}

private struct SkillCardButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .overlay {
        if configuration.isPressed {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.06))
        }
      }
  }
}

// MARK: - Skill Details Content

private struct SkillDetailsContent: View {
  private struct InstallationRowItem: Identifiable {
    let id: String
    let item: InventoryItem
    let showDisambiguatingName: Bool
  }

  let item: SkillWorkspaceItem
  let openClient: (AgentID) -> Void
  var assistance: ((AssistanceInput.Action) -> Void)? = nil
  let editTargets: (() -> Void)?
  let changeInstallMode: (() -> Void)?
  let openSource: (() -> Void)?
  let openOwner: (() -> Void)?

  @State private var copiedInstallationID: String?

  private var trimmedSummary: String {
    item.summary.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedSource: String {
    item.source.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var ownerScopeLabel: String {
    let trimmed = item.scope.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if item.scope.kind == .user {
      return trimmed.isEmpty ? "User Configuration" : trimmed
    }
    return trimmed.isEmpty ? "Workspace" : trimmed
  }

  private var uniqueRecipients: [AgentID] {
    var seen: Set<AgentID> = []
    return item.recipients.filter { seen.insert($0).inserted }
  }

  private var installationRows: [InstallationRowItem] {
    var countsByAgent: [AgentID: Int] = [:]
    for entry in item.installations {
      countsByAgent[entry.id.agent, default: 0] += 1
    }
    return item.installations.enumerated().map { offset, entry in
      let entryName = entry.id.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let hasMultipleForAgent = countsByAgent[entry.id.agent, default: 0] > 1
      let differsFromTitle = !entryName.isEmpty && entryName != item.title
      let key = "\(offset)|\(entry.id.agent.rawValue)|\(entry.id.name)|\(entry.id.path)"
      return InstallationRowItem(
        id: key,
        item: entry,
        showDisambiguatingName: !entryName.isEmpty && (hasMultipleForAgent || differsFromTitle)
      )
    }
  }

  var body: some View {
    Form {
      summarySection
      usedBySection
      if !item.occurrences.isEmpty {
        Section("Declarations") {
          ForEach(Array(item.occurrences.enumerated()), id: \.offset) { _, occurrence in
            DetailsGroup(occurrence.manifestPath + (occurrence.recipients.isEmpty ? "" : " · " + occurrence.recipients.map(\.displayName).joined(separator: ", "))) {
              LabeledContent("Targets", value: occurrence.recipients.map(\.displayName).joined(separator: ", "))
              LabeledContent("Source") { CompactText(text: occurrence.declaringSource) }
              LabeledContent("Owner", value: occurrence.consumerEditable ? "Scope" : "Source")
              if let agents = occurrence.condition.agents { LabeledContent("Clients", value: agents.map(\.displayName).joined(separator: ", ")) }
              if let scopes = occurrence.condition.scopes { LabeledContent("Scopes", value: scopes.map(\.rawValue).joined(separator: ", ")) }
              if let platforms = occurrence.condition.platforms { LabeledContent("Platforms", value: platforms.map(\.rawValue).joined(separator: ", ")) }
            }
          }
        }
      }
      if let assistance {
        Section("Assistance") {
          Button("Explain Skill…") { assistance(.explainSkill) }
          Button("Translate Description…") { assistance(.translateDescription) }
        }
      }
      sourceSection
      if !installationRows.isEmpty {
        installationsSection
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: copiedInstallationID) {
      guard let activeID = copiedInstallationID else { return }
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      if copiedInstallationID == activeID {
        copiedInstallationID = nil
      }
    }
  }

  private var summarySection: some View {
    Section {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: 12) {
          SkillIconView(url: item.iconURL, revision: item.iconRevision, size: 40)

          VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
              .font(.headline)
              .textSelection(.enabled)
            Text(ownerScopeLabel)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        if !trimmedSummary.isEmpty {
          Text(trimmedSummary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.vertical, 2)
    }
  }

  private var usedBySection: some View {
    Section(item.isResolved ? "Used By" : "Requested Targets") {
      if uniqueRecipients.isEmpty {
        Text("No clients")
          .foregroundStyle(.secondary)
      } else if !item.isResolved {
        Text(uniqueRecipients.map(\.displayName).joined(separator: ", "))
        Text("Pending installation").foregroundStyle(.secondary)
      } else {
        ForEach(uniqueRecipients, id: \.self) { agent in
          Button {
            openClient(agent)
          } label: {
            HStack(spacing: 8) {
              Text(agent.displayName)
                .foregroundStyle(.primary)
                .lineLimit(1)
              Spacer(minLength: 8)
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Open \(agent.displayName)")
          .accessibilityHint("Filters view to \(agent.displayName)")
        }
      }

      if let editTargets {
        Button("Edit Targets…", action: editTargets)
          .accessibilityIdentifier("skill.editTargets")
      }
    }
  }

  private var sourceSection: some View {
    Section("Source") {
      LabeledContent("Owner Scope") {
        Text(ownerScopeLabel)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }

      if !item.canEditTargets {
        Text(item.occurrences.contains(where: { !$0.consumerEditable }) ? "Targets are defined by the source." : "Targets are defined across declarations.")
          .font(.callout).foregroundStyle(.secondary)
      }
      if let openOwner {
        Button("Open \(ownerScopeLabel)", action: openOwner)
          .accessibilityIdentifier("skill.openOwner")
      }

      if !trimmedSource.isEmpty {
        LabeledContent("Location") {
          Text(trimmedSource)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(trimmedSource)
        }
      }
      if let owner = item.targetOwner {
        let mode = owner.effectiveMode.skillLabel
        LabeledContent(
          "Install Mode", value: owner.skillOverride.mode == nil ? "\(mode) (Inherited)" : mode)
      } else if let mode = item.resolvedModes.first {
        LabeledContent(
          "Install Mode", value: item.resolvedModes.count == 1 ? mode.skillLabel : "Mixed")
      }
      if let changeInstallMode {
        Button("Change Install Mode…", action: changeInstallMode)
          .accessibilityIdentifier("skill.changeInstallMode")
      } else if item.canEditTargets && !item.canEditInstallMode {
        Text("Install mode can be changed for unpinned local sources.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if let openSource {
        Button("Open Source SKILL.md", action: openSource)
          .accessibilityIdentifier("skill.openSource")
      } else if !item.resolvedModes.contains(.edit), let url = item.sourceURL {
        Button("Show Resolved File in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      }
    }
  }

  private var installationsSection: some View {
    Section {
      ForEach(installationRows) { row in
        installationRow(row)
      }
    } header: {
      HStack(spacing: 6) {
        Text("Installations")
        Spacer()
        Text("\(installationRows.count)")
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
    }
  }

  private func installationRow(_ row: InstallationRowItem) -> some View {
    let entry = row.item
    let entryStatus = entry.status.trimmingCharacters(in: .whitespacesAndNewlines)
    let entryPath = entry.id.path.trimmingCharacters(in: .whitespacesAndNewlines)
    let entryName = entry.id.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let isCopied = copiedInstallationID == row.id

    return VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(entry.id.agent.displayName)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)

        if row.showDisambiguatingName {
          Text(entryName)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }

        Spacer(minLength: 6)

        if !entryStatus.isEmpty {
          Text(entryStatus)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }

      if let version = row.item.version { LabeledContent("Version", value: version) }
      if let revision = row.item.revision { LabeledContent("Revision") { CompactText(text: revision) } }
      if !entryPath.isEmpty {
        HStack(spacing: 6) {
          Text(entryPath)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(entryPath)

          Spacer(minLength: 4)

          Button {
            copyPath(entryPath, rowID: row.id)
          } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
              .font(.caption)
              .foregroundStyle(isCopied ? Color.accentColor : Color.secondary)
              .frame(width: 22, height: 22)
              .contentShape(Rectangle())
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(isCopied ? "Copied path" : "Copy path")
          .help("Copy path")
        }
      }
    }
    .padding(.vertical, 2)
    .contextMenu {
      if let version = row.item.version { LabeledContent("Version", value: version) }
      if let revision = row.item.revision { LabeledContent("Revision") { CompactText(text: revision) } }
      if !entryPath.isEmpty {
        Button("Copy Path") {
          copyPath(entryPath, rowID: row.id)
        }
      }
    }
  }

  private func copyPath(_ path: String, rowID: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(path, forType: .string)
    copiedInstallationID = rowID
  }
}

extension InstallMode {
  var skillLabel: String {
    switch self {
    case .link: "Link"
    case .copy: "Copy"
    case .edit: "Live Edit"
    }
  }
}

// MARK: - Shared Skill Icon Loader & Renderer

private struct SkillIconContent: View {
  private struct LoadKey: Equatable, Sendable {
    let url: URL?
    let maxPixelSize: Int
    let revision: String?
  }

  private enum DecodedIcon: Sendable {
    case cgImage(CGImage)
    case svgData(Data)
  }

  let url: URL?
  let revision: String?
  let size: CGFloat

  @State private var renderedImage: NSImage?
  private static let thumbnails: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 256
    cache.totalCostLimit = 8 * 1024 * 1024
    return cache
  }()
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private nonisolated static let maxIconFileBytes = 1_048_576

  private var maxPixelSize: Int {
    let scaled = Int(ceil(size * max(displayScale, 2.0)))
    return max(32, min(256, scaled))
  }

  private var cornerRadius: CGFloat {
    max(5, round(size * 0.22))
  }

  private var insetPadding: CGFloat {
    size >= 32 ? 4 : 2
  }

  var body: some View {
    let tileShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    ZStack {
      tileShape.fill(Color(nsColor: .controlBackgroundColor))
      tileShape.fill(Color.primary.opacity(reduceTransparency ? 0.08 : 0.05))

      if let renderedImage {
        Image(nsImage: renderedImage)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          .padding(insetPadding)
      } else {
        Image(systemName: "square.stack.3d.up")
          .font(.system(size: round(size * 0.46), weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size)
    .clipShape(tileShape)
    .overlay {
      tileShape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
    }
    .accessibilityHidden(true)
    .task(id: LoadKey(url: url, maxPixelSize: maxPixelSize, revision: revision)) {
      renderedImage = nil
      guard let url, let revision else { return }
      let key = "\(maxPixelSize)|\(revision)|\(url.path)" as NSString
      if let cached = Self.thumbnails.object(forKey: key) {
        renderedImage = cached
        return
      }
      let decoded = await Self.loadBoundedIcon(from: url, maxPixelSize: maxPixelSize)
      guard !Task.isCancelled else { return }
      switch decoded {
      case .cgImage(let cgImage):
        renderedImage = NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
      case .svgData(let data):
        renderedImage = Self.makeBoundedSVGImage(from: data, targetPoints: size)
      case .none:
        renderedImage = nil
      }
      if let renderedImage {
        Self.thumbnails.setObject(renderedImage, forKey: key, cost: maxPixelSize * maxPixelSize * 4)
      }
    }
  }

  private nonisolated static func loadBoundedIcon(
    from url: URL,
    maxPixelSize: Int
  ) async -> DecodedIcon? {
    let worker = Task.detached(priority: .utility) { () -> DecodedIcon? in
      guard !Task.isCancelled, url.isFileURL else { return nil }
      guard let data = SkillMetadataReader.iconData(url, maxBytes: maxIconFileBytes) else {
        return nil
      }
      guard !Task.isCancelled, !data.isEmpty else { return nil }

      if isLikelySVG(url: url, data: data) {
        return .svgData(data)
      }
      if let thumbnail = makeThumbnail(from: data, maxPixelSize: maxPixelSize) {
        return .cgImage(thumbnail)
      }
      return nil
    }

    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  private nonisolated static func isLikelySVG(url: URL, data: Data) -> Bool {
    if url.pathExtension.lowercased() == "svg" {
      return true
    }
    guard let prefix = String(data: data.prefix(512), encoding: .utf8)?.lowercased() else {
      return false
    }
    return prefix.contains("<svg")
  }

  private nonisolated static func makeThumbnail(from data: Data, maxPixelSize: Int) -> CGImage? {
    let sourceOptions: [CFString: Any] = [
      kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary)
    else {
      return nil
    }
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
  }

  private static func makeBoundedSVGImage(from data: Data, targetPoints: CGFloat) -> NSImage? {
    guard let image = NSImage(data: data),
      image.isValid,
      !image.representations.isEmpty
    else {
      return nil
    }
    let sourceSize = image.size
    guard sourceSize.width > 0, sourceSize.height > 0 else {
      return nil
    }
    let scale = min(targetPoints / sourceSize.width, targetPoints / sourceSize.height)
    image.size = NSSize(
      width: max(1, sourceSize.width * scale),
      height: max(1, sourceSize.height * scale)
    )
    return image
  }
}
