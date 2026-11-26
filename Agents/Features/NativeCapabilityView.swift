import AgentsCore
import AgentsUpdates
import SwiftUI

struct NativeCapabilityView: View {
  let model: AppModel
  let snapshot: WorkspaceSnapshot
  let kind: DeclaredComponentKind?

  @State private var moreKind: DeclaredComponentKind = .hook
  @State private var policyScope: WorkspaceScope?
  @State private var pendingConnection: (id: UUID, record: String, readAt: Date)?
  @State private var connectionResults: [String: MCPConnectionTestResult] = [:]

  private static let moreKinds: [DeclaredComponentKind] = [
    .hook, .subagent, .command, .lspServer, .permissions, .ignore, .plugin,
  ]

  private var capability: DeclaredComponentKind { kind ?? moreKind }

  private var components: [ComponentInspection] {
    snapshot.resolvedComponents(of: capability, for: model.clientFilter)
  }

  private var declarations: [DeclarationItem] {
    snapshot.components.filter { $0.record.kind == capability.rawValue }
  }

  var body: some View {
    let components = components
    Form {
      if kind == nil {
        Picker("More Configuration", selection: $moreKind) {
          ForEach(Self.moreKinds, id: \.self) { kind in
            Text(title(for: kind)).tag(kind)
          }
        }
        .accessibilityIdentifier("configuration.kind")
      }

      if capability == .hook, !components.isEmpty {
        let groups = Dictionary(grouping: components, by: hookEvent)
        ForEach(groups.keys.sorted(), id: \.self) { event in
          Section(event) {
            ForEach(groups[event] ?? [], id: \.record) { component in componentRow(component) }
          }
        }
      } else {
        Section(title(for: capability)) {
          if components.isEmpty { emptyState }
          ForEach(components, id: \.record) { component in componentRow(component) }
        }
      }

      if let client = model.clientFilter { capabilityEvidence(for: client) }

      if !declarations.isEmpty {
        Section("Authored Declarations") {
          if model.clientFilter != nil {
            Text("Declarations in the current scope, with their full target selections.")
              .font(.caption).foregroundStyle(.secondary)
          }
          ForEach(declarations) { item in authoredRow(item) }
        }
      }
    }
    .formStyle(.grouped)
    .textSelection(.enabled)
    .toolbar {
      ToolbarItem {
        if capability == .mcpServer {
          Menu("Add MCP Server", systemImage: "plus") {
            Button("Browse MCP Registry…") { model.browseRegistry() }
            Button("Configure Manually…") { addDeclaration() }
          }
          .disabled(!model.canModify)
          .accessibilityIdentifier("mcp.add")
        } else {
          Button("Add Configuration…", systemImage: "plus") { addDeclaration() }
            .disabled(!model.canModify)
        }
      }
      ToolbarItem {
        if capability == .permissions {
          Button("Organization Policy…") { policyScope = snapshot.scope }
        } else if capability == .plugin {
          Button("Manage Packages…") { model.packageScope = snapshot.scope }
            .disabled(!model.canModify)
        }
      }
    }
    .sheet(item: $policyScope) { scope in
      OrganizationPolicySheet(model: model, scope: scope)
    }
    .onChange(of: snapshot.readAt) {
      pendingConnection = nil
      connectionResults.removeAll()
    }
    .onChange(of: model.connectionSession?.result != nil) { _, finished in
      guard finished, let session = model.connectionSession, let result = session.result,
        let pending = pendingConnection, session.id == pending.id, session.scope == snapshot.scope,
        pending.readAt == snapshot.readAt, !session.stale
      else { return }
      connectionResults[pending.record] = result
    }
  }

  @ViewBuilder private var emptyState: some View {
    if let client = model.clientFilter {
      Text(
        "No resolved \(title(for: capability).lowercased()) target \(client.displayName) in this scope."
      )
      .foregroundStyle(.secondary)
      Button("Show All Clients") { model.clientFilter = nil }
    } else {
      Text("No resolved \(title(for: capability).lowercased()) in this scope.")
        .foregroundStyle(.secondary)
    }
  }

  private func componentRow(_ component: ComponentInspection) -> some View {
    DisclosureGroup {
      componentDetail(component)
    } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(component.name)
          Text(clientNames(component.recipients) + " · " + component.source)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        if component.kind == .mcpServer {
          Spacer()
          Text(connectionStatus(for: component))
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityIdentifier("configuration.\(component.kind.rawValue).\(component.record)")
  }

  @ViewBuilder private func componentDetail(_ component: ComponentInspection) -> some View {
    LabeledContent("Scope", value: snapshot.scope.title)
    LabeledContent("Configured Recipients") {
      ClientFilterButtons(recipients: component.recipients) { model.clientFilter = $0 }
    }
    LabeledContent("Source") { CompactText(text: component.source) }
    if let revision = component.revision {
      LabeledContent("Revision") { CompactText(text: revision) }
    }
    if let version = component.version {
      LabeledContent("Version", value: version)
    }
    if let registry = component.mcpRegistry {
      DetailsGroup("Registry Release") {
        LabeledContent("Registry") { CompactText(text: registry.registry) }
        LabeledContent("Server") { CompactText(text: registry.server) }
        LabeledContent("Version", value: registry.version)
        if let package = registry.package {
          LabeledContent("Package") { CompactText(text: package) }
        }
      }
    }
    if component.kind == .mcpServer {
      LabeledContent("Last Connection Test", value: connectionStatus(for: component))
      if let result = connectionResults[component.record], let issue = result.issue {
        Text(ConnectionLabels.issue(issue)).foregroundStyle(.secondary)
      }
      Button("Test Connection…") {
        model.beginConnection(component)
        if let session = model.connectionSession, session.selection == component.selection {
          pendingConnection = (session.id, component.record, snapshot.readAt)
        }
      }
      .disabled(model.isTerminating || model.isApplying || model.connectionSession != nil)
      .accessibilityIdentifier("mcp.testConnection")
    }
    DetailsGroup("Configuration") {
      if case .object(let fields) = component.configuration {
        ForEach(fields.keys.sorted(), id: \.self) { key in
          if let value = fields[key] {
            CapabilityValueRow(key: key, value: value)
          }
        }
      } else {
        CapabilityValueRow(key: "Value", value: component.configuration)
      }
    }
    let deployments = snapshot.inspection.deployments.filter {
      $0.ownerRecords.contains(component.record)
    }
    if !deployments.isEmpty {
      DetailsGroup("Output Files") {
        ForEach(deployments, id: \.identity) { deployment in
          DetailsGroup(deployment.location.lastPathComponent) {
            LabeledContent("Location") { PathView(url: deployment.location, scope: snapshot.scope) }
            LabeledContent("On Disk", value: deployment.status.configurationLabel)
            LabeledContent("Format", value: deployment.format)
            LabeledContent("Ownership", value: deployment.ownership)
            LabeledContent(
              "Output Recipients",
              value: clientNames(deployment.recipients))
            if let readers = deployment.effectiveReaders {
              LabeledContent("Known File Readers", value: clientNames(readers))
            }
            if deployment.privateMaterialization {
              Label("Contains private material", systemImage: "lock")
            }
            if let diagnostic = deployment.diagnostic { Text(verbatim: diagnostic) }
          }
        }
      }
    }
    let resources = snapshot.inspection.resources.filter {
      component.resources.contains($0.identity)
    }
    if !resources.isEmpty {
      DetailsGroup("Resources") {
        ForEach(resources, id: \.identity) { resource in
          LabeledContent(resource.kind.capitalized) {
            if let url = resource.location {
              PathView(url: url, scope: snapshot.scope)
            } else {
              CompactText(text: resource.path)
            }
          }
        }
      }
    }
    ForEach(component.occurrences, id: \.selection) { occurrence in
      ConfigurationOccurrenceDetails(occurrence: occurrence)
    }
    Menu("Component Actions", systemImage: "ellipsis.circle") {
      Button("Preview Update…") {
        model.previewUpdate(
          title: "Update Component", request: .init(selections: [component.selection]))
      }
      Button("Preview Removal…") {
        model.previewUpdate(
          title: "Remove Component",
          request: .init(operation: .remove, selections: [component.selection]))
      }
    }.disabled(!model.canModify)
  }

  private func authoredRow(_ item: DeclarationItem) -> some View {
    DetailsGroup(item.container == "Scope" ? item.title : item.container + " · " + item.title) {
      LabeledContent("File") { PathView(url: snapshot.manifestURL, scope: snapshot.scope) }
      RecordFields(
        record: item.record, pointer: item.pointer,
        authored: snapshot.document.map { AuthoredFields(sourceMap: $0.sourceMap) })
      Button("Edit Declaration…") {
        model.selectedItem = item.id
        model.editSelectedDeclaration()
      }.disabled(!model.canModify)
      Button("Move or Remove…") {
        model.beginDraft(.structure)
        model.manifestDraft?.structuralNode = item.id
      }.disabled(!model.canModify)
    }
  }

  @ViewBuilder private func capabilityEvidence(for client: AgentID) -> some View {
    let installScope = snapshot.scope.installScope
    let evidence = AgentClientOperations.schemaEvidence(for: client).filter {
      $0.kind == capability
        && ($0.scope == installScope.rawValue
          || (capability == .mcpServer && installScope == .project && $0.scope == "local"))
    }
    if !evidence.isEmpty {
      Section {
        DetailsGroup("Adapter Support · " + client.displayName) {
          ForEach(Array(evidence.enumerated()), id: \.offset) { _, format in
            LabeledContent(
              format.surface.displayName + " · " + ClientLabels.scope(format.scope)
                + (format.placement == .pluginMember ? " · Plugin Member" : ""),
              value: ClientLabels.evidence(format.status))
            if let limitation = format.limitation {
              Text(verbatim: limitation).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  private func addDeclaration() {
    model.beginDraft(.component)
    model.manifestDraft?.component.kind = capability
  }

  private func connectionStatus(for component: ComponentInspection) -> String {
    guard let result = connectionResults[component.record] else { return "Not tested" }
    if result.issue == .cancelled { return "Cancelled" }
    return ConnectionLabels.outcome(result.outcome)
  }

  private func hookEvent(_ component: ComponentInspection) -> String {
    guard case .object(let fields) = component.configuration else { return "Hooks" }
    switch fields["event"] {
    case .string("beforeTool"): return "Before Tool"
    case .string("afterTool"): return "After Tool"
    case .string("sessionStart"): return "Session Start"
    case .string("sessionEnd"): return "Session End"
    case .object(let event):
      if case .string(let name) = event["native"] { return name }
      return "Hooks"
    default: return "Hooks"
    }
  }

  private func title(for kind: DeclaredComponentKind) -> String {
    switch kind {
    case .mcpServer: "MCP Servers"
    case .hook: "Hooks"
    case .subagent: "Subagents"
    case .command: "Commands"
    case .lspServer: "Language Servers"
    case .permissions: "Permissions"
    case .ignore: "Ignore Patterns"
    case .plugin: "Plugins"
    default: DeclarationLabels.kind(kind.rawValue)
    }
  }
}

extension WorkspaceSnapshot {
  func resolvedComponents(of kind: DeclaredComponentKind, for recipient: AgentID?)
    -> [ComponentInspection]
  {
    inspection.components.filter {
      $0.kind == kind && (recipient.map($0.recipients.contains) ?? true)
    }.sorted {
      if $0.name != $1.name {
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
      if $0.source != $1.source { return $0.source < $1.source }
      return $0.record < $1.record
    }
  }
}

struct ConfigurationOccurrenceDetails: View {
  let occurrence: OccurrenceInspection

  var body: some View {
    DetailsGroup("Declared in " + occurrence.manifestPath) {
      LabeledContent("Source") { CompactText(text: occurrence.declaringSource) }
      LabeledContent(
        "Ownership",
        value: occurrence.consumerEditable ? "Scope Declaration" : "Source Declaration")
      LabeledContent("Recipients", value: clientNames(occurrence.recipients))
      if let agents = occurrence.condition.agents {
        LabeledContent("Condition Recipients", value: clientNames(agents))
      }
      if let scopes = occurrence.condition.scopes {
        LabeledContent(
          "Condition Scopes",
          value: scopes.isEmpty ? "None" : scopes.map(\.rawValue).joined(separator: ", "))
      }
      if let platforms = occurrence.condition.platforms {
        LabeledContent(
          "Condition Platforms",
          value: platforms.isEmpty ? "None" : platforms.map(\.rawValue).joined(separator: ", "))
      }
    }
  }
}

struct ClientFilterButtons: View {
  let recipients: [AgentID]
  let show: (AgentID) -> Void

  var body: some View {
    if recipients.isEmpty {
      Text("None").foregroundStyle(.secondary)
    } else {
      VStack(alignment: .trailing, spacing: 4) {
        ForEach(recipients, id: \.self) { client in
          Button(client.displayName) { show(client) }
            .buttonStyle(.link)
            .accessibilityHint("Filter to " + client.displayName)
        }
      }
    }
  }
}

private func clientNames(_ recipients: [AgentID]) -> String {
  recipients.isEmpty ? "None" : recipients.map(\.displayName).joined(separator: ", ")
}

extension DeploymentInspection.Status {
  var configurationLabel: String {
    switch self {
    case .current: "Verified"
    case .missing: "Missing"
    case .drifted: "Changed on Disk"
    case .unverified: "Unverified"
    }
  }
}

private struct CapabilityValueRow: View {
  let key: String
  let value: NativeValue

  private var title: String { DeclarationLabels.field(key) }

  var body: some View {
    if key == "environment" || key == "headers", case .object(let fields) = value {
      DetailsGroup(title) {
        ForEach(fields.keys.sorted(), id: \.self) { name in
          if case .object(let binding) = fields[name] {
            if case .string(let variable) = binding["environment"] {
              LabeledContent(name, value: "Environment: " + variable)
            } else if case .string(let reference) = binding["secret"] {
              LabeledContent(name, value: "Secret reference: " + reference)
            }
          } else {
            LabeledContent(name, value: "Value hidden")
          }
        }
      }
    } else {
      valueRow
    }
  }

  @ViewBuilder private var valueRow: some View {
    switch value {
    case .string(let text):
      if key == "prompt" || key == "description" {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.caption).foregroundStyle(.secondary)
          Text(verbatim: text)
        }
      } else {
        LabeledContent(title) {
          CompactText(text: key == "url" ? endpoint(text) : text)
        }
      }
    case .integer(let number): LabeledContent(title, value: String(number))
    case .decimal(let text): LabeledContent(title, value: text)
    case .boolean(let value): LabeledContent(title, value: value ? "True" : "False")
    case .null: LabeledContent(title, value: "Explicit null")
    case .array(let items):
      DetailsGroup(title + " (\(items.count))") {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          CapabilityValueRow(key: String(index + 1), value: item)
        }
      }
    case .object(let fields):
      DetailsGroup(title) {
        ForEach(fields.keys.sorted(), id: \.self) { key in
          if let value = fields[key] { CapabilityValueRow(key: key, value: value) }
        }
      }
    }
  }

  private func endpoint(_ url: String) -> String {
    guard var parts = URLComponents(string: url), parts.host != nil else { return "URL hidden" }
    parts.user = nil
    parts.password = nil
    parts.query = nil
    parts.fragment = nil
    return parts.string ?? "URL hidden"
  }
}
