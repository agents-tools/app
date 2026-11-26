import AgentsCore
import AgentsUpdates
import AppKit
import SwiftUI

struct InstructionsView: View {
  private enum Presentation: Hashable { case units, output }

  @Bindable var model: AppModel
  let snapshot: WorkspaceSnapshot

  @State private var presentation: Presentation = .units
  @State private var mappingID: String?

  private var mapping: MappingItem? {
    snapshot.mappings.first { $0.id == mappingID }
      ?? snapshot.mappings.first { $0.scope == snapshot.scope }
  }

  private var displayedScope: WorkspaceScope {
    if presentation == .output, let mapping { return mapping.scope }
    return snapshot.scope
  }

  private var canBuildDisplayedScope: Bool {
    model.canModify && displayedScope == model.scope
  }

  private var units: [ComponentInspection] {
    snapshot.resolvedComponents(of: .instructions, for: model.clientFilter).filter {
      if case .object(let fields) = $0.configuration, fields["prompt"] != nil { return false }
      return !$0.chatGPT
    }
  }

  var body: some View {
    Form {
      Picker("Instructions", selection: $presentation) {
        Text("Instruction Units").tag(Presentation.units)
        Text("Client Output").tag(Presentation.output)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("instructions.presentation")

      switch presentation {
      case .units:
        unitList
        authoredInstructions
        localInstructions
      case .output:
        if let mapping { outputConfiguration(mapping) }
        appOutputs(in: displayedScope)
        if let mapping {
          clientOutput(mapping)
          if !mapping.prompts.isEmpty { namedPrompts(mapping) }
        }
      }
    }
    .formStyle(.grouped)
    .textSelection(.enabled)
    .onChange(of: snapshot.scope) { mappingID = nil }
    .toolbar {
      ToolbarItem {
        Button("Build Instructions…") {
          model.previewUpdate(UpdateProposal(compilingInstructionsIn: displayedScope))
        }
        .disabled(!canBuildDisplayedScope)
        .accessibilityIdentifier("instructions.build")
      }
      ToolbarItem {
        Menu("Instruction Actions", systemImage: "ellipsis.circle") {
          Button("Add Instructions…", action: addInstructions).disabled(!model.canModify)
          if snapshot.scope.kind == .project {
            Button("New Local Instructions…") { model.beginCreation(.instructions) }
          }
          Button("Choose Mapping Projects…") { model.chooseMappings() }
          Button("Copy All Mappings") {
            copyText(snapshot.mappings.map(\.copyText).joined(separator: "\n\n"))
          }.disabled(snapshot.mappings.isEmpty)
        }
        .accessibilityIdentifier("instructions.actions")
      }
    }
  }

  private var unitList: some View {
    Section("Resolved Instruction Units") {
      if units.isEmpty {
        if let client = model.clientFilter {
          Text("No resolved instruction units target \(client.displayName) in this scope.")
            .foregroundStyle(.secondary)
          Button("Show All Clients") { model.clientFilter = nil }
        } else {
          Text("No resolved instruction units in this scope.").foregroundStyle(.secondary)
        }
      }
      ForEach(units, id: \.record) { unit in
        DetailsGroup(unit.name) {
          LabeledContent("Source") { CompactText(text: unit.source) }
          if let revision = unit.revision {
            LabeledContent("Revision") { CompactText(text: revision) }
          }
          LabeledContent("Configured Recipients") {
            VStack(alignment: .trailing, spacing: 4) {
              if !unit.recipients.isEmpty || unit.copyRecipients.isEmpty {
                ClientFilterButtons(recipients: unit.recipients) { client in
                  model.clientFilter = client
                  mappingID = nil
                  presentation = .output
                }
              }
              ForEach(unit.copyRecipients, id: \.self) { recipient in
                Text(recipient.displayName)
              }
            }
          }
          let resources = snapshot.inspection.resources.filter {
            unit.resources.contains($0.identity)
          }
          ForEach(resources, id: \.identity) { resource in
            LabeledContent("Source File") { CompactText(text: resource.path) }
          }
          ForEach(unit.occurrences, id: \.selection) { occurrence in
            ConfigurationOccurrenceDetails(occurrence: occurrence)
          }
          let deployments = snapshot.inspection.deployments.filter {
            $0.ownerRecords.contains(unit.record)
          }
          if !deployments.isEmpty {
            DetailsGroup("Mapped Files") {
              ForEach(deployments, id: \.identity) { deployment in
                LabeledContent(deployment.status.configurationLabel) {
                  PathView(url: deployment.location, scope: snapshot.scope)
                }
              }
              Button("View Client Output") {
                mappingID = nil
                presentation = .output
              }
            }
          }
        }
      }
    }
  }

  private var authoredInstructions: some View {
    Section("Instruction Declarations") {
      if snapshot.instructions.isEmpty {
        Text("No instruction components are declared here.").foregroundStyle(.secondary)
      } else if model.clientFilter != nil {
        Text("Edit declarations in this scope with their full target selections.")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(snapshot.instructions) { item in
        DetailsGroup(declarationTitle(item)) {
          Button("Edit Instructions…") { editInstructions(item) }.disabled(!model.canModify)
          RecordFields(
            record: item.record, pointer: item.pointer,
            authored: snapshot.document.map { AuthoredFields(sourceMap: $0.sourceMap) })
          let prompts =
            item.record["chatGPT"]?.elements?.compactMap(\.record).compactMap {
              $0["name"]?.string
            } ?? []
          ForEach(Array(prompts.enumerated()), id: \.offset) { _, name in
            Button("Generate “\(name)”…") { model.previewPrompt(name: name, in: snapshot.scope) }
          }
        }
      }
    }
  }

  private func addInstructions() {
    model.beginDraft(.component)
    model.manifestDraft?.component.kind = .instructions
  }

  private func editInstructions(_ item: DeclarationItem) {
    model.selectedItem = item.id
    model.editSelectedDeclaration()
  }

  private func declarationTitle(_ item: DeclarationItem) -> String {
    let title = item.container == "Scope" ? item.title : item.container + " · " + item.title
    guard let section = item.record["sections"]?.elements?.first?.record,
      let name = section["name"]?.string
    else { return title }
    return title + " · "
      + SectionDeclaration(name: name, source: section["source"]?.string).reference
  }

  @ViewBuilder private var localInstructions: some View {
    if snapshot.scope.kind == .project {
      Section("Local Author Files") {
        if let own = snapshot.ownInstructions {
          if own.isEmpty {
            Text("No local instruction files found.").foregroundStyle(.secondary)
          }
          ForEach(own) { item in
            DetailsGroup(item.heading) {
              if !item.description.isEmpty { Text(item.description) }
              LabeledContent("Location") { PathView(url: item.authorFile, scope: snapshot.scope) }
              if !item.paths.isEmpty {
                LabeledContent("Paths", value: item.paths.joined(separator: ", "))
              }
              Button("Open Author File") { NSWorkspace.shared.open(item.authorFile) }
            }
          }
        } else {
          Text("Local instructions are unavailable. See Diagnostics.").foregroundStyle(.secondary)
        }
      }
    }
  }

  private func outputConfiguration(_ mapping: MappingItem) -> some View {
    Section {
      if snapshot.mappings.count > 1 {
        Picker("Configuration", selection: Binding(get: { mapping.id }, set: { mappingID = $0 })) {
          ForEach(snapshot.mappings) { item in Text(item.title).tag(item.id) }
        }
        .accessibilityIdentifier("instructions.output.scope")
      }
      LabeledContent("Location") { PathView(url: mapping.scope.root, scope: mapping.scope) }
      Text(mapping.status).foregroundStyle(.secondary)
      if mapping.scope != snapshot.scope {
        Button("Open " + mapping.scope.title) { model.select(mapping.scope) }
          .disabled(model.isApplying || model.isTerminating)
      }
      if snapshot.scope.kind == .project {
        Text("Each mapping covers one scope. Client precedence across scopes is unavailable here.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func appOutputs(in scope: WorkspaceScope) -> some View {
    Section("App Destinations") {
      ForEach(InstructionAppDestination.inScope(scope, snapshot: snapshot)) { destination in
        LabeledContent {
          Button("Preview Output…") {
            previewOutput(.app(destination.recipient), in: scope)
          }
          .disabled(!canBuildDisplayedScope)
          .accessibilityLabel("Preview " + destination.recipient.displayName + " output")
          .accessibilityIdentifier("instructions.output.preview." + destination.recipient.rawValue)
        } label: {
          Text(destination.recipient.displayName)
          Text(destination.status)
        }
        .accessibilityIdentifier("instructions.output.app." + destination.recipient.rawValue)
      }
      if scope == model.scope && scope == snapshot.scope {
        Text("Choose app recipients for each section in your instruction declarations.")
          .font(.caption).foregroundStyle(.secondary)
        editAppRecipients.disabled(!canBuildDisplayedScope)
      }
    }
  }

  @ViewBuilder private var editAppRecipients: some View {
    if snapshot.instructions.isEmpty {
      Button("Add Instruction Declaration…", action: addInstructions)
        .accessibilityIdentifier("instructions.output.add")
    } else if let item = snapshot.instructions.first, snapshot.instructions.count == 1 {
      Button("Edit Instruction Units…") { editInstructions(item) }
        .accessibilityIdentifier("instructions.output.edit")
    } else {
      Menu("Edit Instruction Units…") {
        ForEach(snapshot.instructions) { item in
          Button(declarationTitle(item)) { editInstructions(item) }
        }
      }
      .accessibilityIdentifier("instructions.output.edit")
    }
  }

  private func clientOutput(_ mapping: MappingItem) -> some View {
    Section("Local Output Files") {
      if let client = model.clientFilter,
        !client.supportsInstructions(in: mapping.scope.installScope)
      {
        Text(
          "\(client.displayName) does not support \(mapping.scope.installScope.rawValue) instruction output."
        )
        .foregroundStyle(.secondary)
      }
      let targets = mapping.targets(for: model.clientFilter)
      if targets.isEmpty {
        if let client = model.clientFilter {
          Text("No mapped files for \(client.displayName).").foregroundStyle(.secondary)
          Button("Show All Clients") { model.clientFilter = nil }
        } else {
          Text("No mapped instruction files.").foregroundStyle(.secondary)
        }
        if model.clientFilter?.supportsInstructions(in: mapping.scope.installScope) != false {
          Button("Preview Local Outputs…") {
            previewOutput(.local(recipient: model.clientFilter), in: mapping.scope)
          }
          .disabled(!canBuildDisplayedScope)
          .accessibilityIdentifier("instructions.output.preview.local")
        }
      }
      ForEach(targets) { target in
        DetailsGroup(target.id) { outputFile(target, in: mapping) }
          .accessibilityIdentifier("instructions.output.file." + target.id)
      }
      if model.clientFilter == nil, !mapping.unplaced.isEmpty {
        DetailsGroup("Unassigned Sections") { orderedSections(mapping.unplaced) }
      }
      Button("Copy Mapping") { copyText(mapping.copyText) }
    }
  }

  @ViewBuilder private func outputFile(_ target: MappingTarget, in mapping: MappingItem)
    -> some View
  {
    if let url = mapping.fileURL(for: target.id) {
      LabeledContent("Path") { PathView(url: url, scope: mapping.scope) }
      Button("Preview Output…") {
        previewOutput(.local(file: url, recipient: model.clientFilter), in: mapping.scope)
      }
      .disabled(!canBuildDisplayedScope)
      .accessibilityIdentifier("instructions.output.preview." + target.id)
    }
    LabeledContent("Mapped Recipients") {
      ClientFilterButtons(recipients: target.recipients) { model.clientFilter = $0 }
    }
    if target.recipients.count > 1 {
      Label("Shared Output File", systemImage: "doc.on.doc")
        .font(.caption).foregroundStyle(.secondary)
    }
    let deployment = mapping.deployment(for: target, in: snapshot)
    if let deployment {
      LabeledContent("On Disk", value: deployment.status.configurationLabel)
      if let diagnostic = deployment.diagnostic {
        Text(verbatim: diagnostic).foregroundStyle(.secondary)
      }
    }
    let readers = deployment?.effectiveReaders
    LabeledContent(
      "Known File Readers",
      value: readers?.map(\.displayName).joined(separator: ", ") ?? "Unreported")
    if let reference = target.importedFile {
      LabeledContent("Imports", value: reference)
      if let imported = mapping.importedTarget(for: target) {
        DetailsGroup("Sections in " + imported.id) { orderedSections(imported.sections) }
      }
    } else if !target.sections.isEmpty {
      DetailsGroup("Sections in File Order") { orderedSections(target.sections) }
    }
  }

  private func previewOutput(_ focus: InstructionOutputFocus, in scope: WorkspaceScope) {
    model.previewUpdate(UpdateProposal(compilingInstructionsIn: scope, focus: focus))
  }

  private func namedPrompts(_ mapping: MappingItem) -> some View {
    Section("Named Prompts · " + mapping.title) {
      ForEach(mapping.prompts.keys.sorted(), id: \.self) { name in
        DetailsGroup(name) {
          Button("Preview…") { model.previewPrompt(name: name, in: mapping.scope) }
            .accessibilityLabel("Preview " + name)
          orderedSections(mapping.prompts[name] ?? [])
        }
      }
    }
  }

  private func orderedSections(_ sections: [LockedSection]) -> some View {
    ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
      VStack(alignment: .leading, spacing: 2) {
        Text("\(index + 1). \(section.name)")
        Text(section.source + " · " + section.path)
          .font(.caption).foregroundStyle(.secondary)
      }.accessibilityElement(children: .combine)
    }
  }
}

struct InstructionAppDestination: Identifiable {
  let recipient: InstructionRecipient
  let hasResolvedUnits: Bool?
  var id: InstructionRecipient { recipient }

  var status: String {
    switch hasResolvedUnits {
    case .some(true): "Resolved instruction units available"
    case .some(false): "No resolved instruction units"
    case nil: "Open this configuration to see its instruction units"
    }
  }

  static func inScope(_ scope: WorkspaceScope, snapshot: WorkspaceSnapshot) -> [Self] {
    [InstructionRecipient.chatGPTApp, .geminiApp].map { recipient in
      let hasResolvedUnits =
        scope == snapshot.scope
        ? snapshot.inspection.components.contains { $0.copyRecipients.contains(recipient) }
        : nil
      return Self(recipient: recipient, hasResolvedUnits: hasResolvedUnits)
    }
  }
}

extension MappingItem {
  func targets(for recipient: AgentID?) -> [MappingTarget] {
    guard let recipient else { return targets }
    return targets.filter { $0.recipients.contains(recipient) }
  }

  func fileURL(for path: String) -> URL? {
    if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
    if path.hasPrefix("~/") {
      guard scope.kind == .user else { return nil }
      return scope.root.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
    }
    return scope.root.appendingPathComponent(path).standardizedFileURL
  }

  func importedTarget(for target: MappingTarget) -> MappingTarget? {
    guard let reference = target.importedFile, let file = fileURL(for: target.id) else {
      return nil
    }
    let imported = file.deletingLastPathComponent().appendingPathComponent(reference)
      .standardizedFileURL
    return targets.first { $0.id != target.id && fileURL(for: $0.id) == imported }
  }

  func deployment(for target: MappingTarget, in snapshot: WorkspaceSnapshot)
    -> DeploymentInspection?
  {
    guard snapshot.scope == scope, let url = fileURL(for: target.id) else { return nil }
    return snapshot.inspection.deployments.first {
      $0.location.standardizedFileURL == url
        && ["agents/instructions@1", "agents/claude-import@1", "agents/antigravity-rule@1"]
          .contains($0.format)
    }
  }
}
