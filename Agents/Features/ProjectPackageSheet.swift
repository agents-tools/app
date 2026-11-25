import AgentsCore
import AgentsUpdates
import AppKit
import SwiftUI

struct ProjectPackageSheet: View {
  let snapshot: WorkspaceSnapshot
  let environment: RuntimeEnvironment

  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var version = "1.0.0"
  @State private var packageAuthor = ""
  @State private var packageDescription = ""
  @State private var instructions = Set<String>()
  @State private var skills = Set<String>()
  @State private var servers = Set<String>()
  @State private var locked = Set<String>()
  @State private var target: NativePluginTarget?
  @State private var marketplace = ""
  @State private var marketplaceCategory = ""
  @State private var capture: AuthorPackageArtifact?
  @State private var plugin: NativePluginArtifact?
  @State private var busy = false
  @State private var failure: String?
  @State private var saved: URL?

  private var lockedComponents: [ComponentInspection] {
    snapshot.inspection.components.filter {
      [.instructions, .skills, .mcpServer].contains($0.kind)
    }
  }

  private var serverNames: [String] {
    (snapshot.inspection.declaration?.components ?? []).compactMap { component in
      guard case .mcpServer(let name, _, _, nil, _, nil) = component else { return nil }
      return name
    }.sorted()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(capture == nil ? "Package Project" : "Review Package").font(.title2.bold())
      Text(snapshot.scope.title).foregroundStyle(.secondary)
      Form {
        if let capture {
          Section(capture.inspection.package.name + " · " + capture.inspection.package.version) {
            LabeledContent("Digest") {
              Text(plugin?.digest ?? capture.digest).textSelection(.enabled)
            }
            ForEach(capture.inspection.components, id: \.id) { member in
              LabeledContent(member.name, value: DeclarationLabels.kind(member.kind.rawValue))
            }
            DisclosureGroup("Included Files") {
              let paths =
                plugin?.entries.map(\.path)
                ?? capture.includedPaths.map { $0.member.name + " / " + $0.entry.path }
              ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                Text(path).textSelection(.enabled)
              }
            }
          }
          let warnings = plugin?.warnings ?? capture.warnings
          ForEach(Array(warnings.enumerated()), id: \.offset) { _, item in
            LabeledContent(item.member.name, value: "\(item.count) credential fields omitted")
          }
          ForEach(
            Array((plugin?.contentFindings ?? capture.contentFindings).enumerated()), id: \.offset
          ) { _, item in
            Text(item.location.path + " · " + item.message)
          }
          ForEach(
            Array((plugin?.policyFindings ?? capture.policyFindings).enumerated()), id: \.offset
          ) { _, item in
            Text(item.identity + " · " + item.message)
          }
        } else {
          Section("Package") {
            TextField("Name", text: $name)
            TextField("Version", text: $version)
            Picker("Format", selection: $target) {
              Text("Agents Bundle").tag(NativePluginTarget?.none)
              ForEach(NativePluginTarget.allCases, id: \.self) { item in
                Text(item.rawValue).tag(Optional(item))
              }
            }
            if target != nil {
              TextField("Author", text: $packageAuthor)
              TextField("Description", text: $packageDescription)
              TextField("Marketplace name (optional)", text: $marketplace)
              if target == .codex && !marketplace.isEmpty {
                TextField("Marketplace category", text: $marketplaceCategory)
              }
            }
          }
          if let own = snapshot.ownInstructions, !own.isEmpty {
            Section("Project Instructions") {
              ForEach(own) { item in
                Toggle(item.id.name, isOn: binding($instructions, item.id.name))
              }
            }
          }
          Section("Skill Directories") {
            ForEach(skills.sorted(), id: \.self) { path in
              HStack {
                Text(path)
                Spacer()
                Button("Remove") { skills.remove(path) }
              }
            }
            Button("Choose Directories…") { chooseSkills() }
          }
          if !serverNames.isEmpty {
            Section("Project MCP Servers") {
              ForEach(serverNames, id: \.self) { name in Toggle(name, isOn: binding($servers, name))
              }
            }
          }
          if !lockedComponents.isEmpty {
            Section("Locked Components") {
              ForEach(lockedComponents, id: \.record) { member in
                Toggle(
                  member.name + " · " + DeclarationLabels.kind(member.kind.rawValue),
                  isOn: binding($locked, member.record))
              }
            }
          }
        }
      }.formStyle(.grouped)
      if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
      if let saved { Text(saved.path).textSelection(.enabled) }
      HStack {
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        if let capture {
          Button("Edit Selection") {
            self.capture = nil
            plugin = nil
            saved = nil
            failure = nil
          }
          Button("Export…") { chooseOutput(capture, destination: .file) }
          if plugin == nil {
            Menu("Publish") {
              Button("To Directory Marketplace…") { chooseOutput(capture, destination: .catalog) }
              Button("Stage for HTTPS Hosting…") { chooseOutput(capture, destination: .hosting) }
            }
          }
        } else {
          if FileManager.default.fileExists(
            atPath: environment.projectDirectory.appendingPathComponent(
              AuthorPackageOperations.specificationFilename
            ).path)
          {
            Button("Review Project Specification…") { prepare(usingFile: true) }
              .disabled(needsMarketplaceCategory)
          }
          Button("Review Selection…") { prepare(usingFile: false) }
            .disabled(
              name.isEmpty || version.isEmpty || needsMarketplaceCategory
                || (target != nil && (packageAuthor.isEmpty || packageDescription.isEmpty))
                || (instructions.isEmpty && skills.isEmpty && servers.isEmpty && locked.isEmpty))
        }
      }
    }.padding(20).frame(minWidth: 570, minHeight: 450)
      .disabled(busy).interactiveDismissDisabled(busy)
  }

  private func binding(_ selection: Binding<Set<String>>, _ value: String) -> Binding<Bool> {
    Binding(
      get: { selection.wrappedValue.contains(value) },
      set: { selected in
        if selected {
          selection.wrappedValue.insert(value)
        } else {
          selection.wrappedValue.remove(value)
        }
      })
  }

  private func chooseSkills() {
    let panel = NSOpenPanel()
    panel.directoryURL = environment.projectDirectory
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    let base = environment.projectDirectory.standardizedFileURL.pathComponents
    var selected = Set<String>()
    for url in panel.urls {
      let parts = url.standardizedFileURL.pathComponents
      guard parts.count > base.count, parts.starts(with: base) else {
        failure = "Choose a skill directory inside this project."
        return
      }
      selected.insert(parts.dropFirst(base.count).joined(separator: "/"))
    }
    failure = nil
    skills.formUnion(selected)
  }

  private var needsMarketplaceCategory: Bool {
    target == .codex && !marketplace.isEmpty && marketplaceCategory.isEmpty
  }

  private func prepare(usingFile: Bool) {
    let selected = lockedComponents.filter { locked.contains($0.record) }
    let spec = AuthorPackageSpecification(
      package: .init(
        name: name, version: version, description: target == nil ? nil : packageDescription,
        author: target == nil ? nil : packageAuthor),
      instructions: instructions.sorted(), skills: skills.sorted(), mcpServers: servers.sorted(),
      lockedMembers: selected.map { MarketplaceMemberKey(kind: $0.kind, name: $0.name) })
    let catalog =
      marketplace.isEmpty
      ? nil
      : NativePluginMarketplace(
        name: marketplace, category: target == .codex ? marketplaceCategory : nil)
    let format = target
    let runtime = environment
    run {
      let package =
        try usingFile
        ? AuthorPackageOperations.preview(environment: runtime)
        : AuthorPackageOperations.preview(spec, environment: runtime)
      let plugin = try format.map {
        try NativePluginOperations.preview(
          package, for: $0, marketplace: catalog, environment: runtime)
      }
      return (package, plugin)
    } receive: { result in
      capture = result.0
      plugin = result.1
      saved = nil
    }
  }

  private enum Destination: Sendable { case file, catalog, hosting }

  private func chooseOutput(_ package: AuthorPackageArtifact, destination: Destination) {
    let output: URL
    if destination != .file {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.prompt = destination == .hosting ? "Stage" : "Publish"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      output = url
    } else {
      let panel = NSSavePanel()
      panel.nameFieldStringValue =
        package.inspection.package.name + (plugin == nil ? ".agentsbundle" : "")
      guard panel.runModal() == .OK, let url = panel.url else { return }
      output = url
    }
    let runtime = environment
    let native = plugin
    run {
      if let native {
        try NativePluginOperations.write(native, to: output, environment: runtime)
      } else if destination == .hosting {
        return try MarketplaceOperations.exportHostedBundle(
          package.archive, to: output, summary: package.inspection.package.description,
          environment: runtime)
      } else if destination == .catalog {
        try AuthorPackageOperations.publish(package, to: output, environment: runtime)
      } else {
        try AuthorPackageOperations.write(package, to: output, environment: runtime)
      }
      return output
    } receive: {
      saved = $0
    }
  }

  private func run<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T, receive: @escaping (T) -> Void
  ) {
    busy = true
    failure = nil
    Task {
      defer { busy = false }
      do { receive(try await Task.detached(priority: .userInitiated, operation: work).value) } catch
      { failure = String(describing: error) }
    }
  }
}
