import AgentsCore
import AgentsUpdates
import AppKit
import SwiftUI

struct BundleAuthoringSheet: View {
  let snapshot: WorkspaceSnapshot
  let environment: RuntimeEnvironment
  let didPublish: (MarketplaceOrigin) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selection = Set<String>()
  @State private var name = ""
  @State private var version = "1.0.0"
  @State private var working = false
  @State private var notice: String?
  @State private var failure: String?

  private var components: [ComponentInspection] {
    snapshot.inspection.components.filter {
      [.skills, .instructions, .mcpServer].contains($0.kind)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Create Bundle").font(.headline)
      Text(snapshot.scope.title).foregroundStyle(.secondary)
      Grid(alignment: .leading) {
        GridRow {
          Text("Package name")
          TextField("Name", text: $name).labelsHidden()
        }
        GridRow {
          Text("Version")
          TextField("Version", text: $version).labelsHidden()
        }
      }
      List(selection: $selection) {
        ForEach(components, id: \.record) { component in
          HStack {
            VStack(alignment: .leading) {
              Text(component.name)
              Text(component.source).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(component.source)
            }
            Spacer()
            Text(DeclarationLabels.kind(component.kind.rawValue)).foregroundStyle(.secondary)
          }.tag(component.record)
        }
      }.accessibilityLabel("Bundle components")
      if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
      if let notice { Text(notice).textSelection(.enabled) }
      HStack {
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if working { ProgressView().controlSize(.small) }
        Button("Export File…") { chooseDestination(publishing: false) }.disabled(!ready)
        Button("Publish to Marketplace…") { chooseDestination(publishing: true) }.disabled(!ready)
      }
    }.padding(20).frame(minWidth: 580, minHeight: 390)
      .disabled(working).interactiveDismissDisabled(working)
  }

  private var ready: Bool { !selection.isEmpty && !name.isEmpty && !version.isEmpty && !working }

  private func chooseDestination(publishing: Bool) {
    let destination: URL
    if publishing {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.allowsMultipleSelection = false
      panel.prompt = "Publish"
      panel.message = "Publish " + name + " " + version + " to this marketplace."
      guard panel.runModal() == .OK, let url = panel.url else { return }
      destination = url
    } else {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = URL(fileURLWithPath: name).lastPathComponent + ".agentsbundle"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      destination = url
    }
    let package = BundlePackage(name: name, version: version)
    let entries = components.filter { selection.contains($0.record) }.map(\.selection)
    let scope = snapshot.scope.installScope
    let runtime = environment
    working = true
    failure = nil
    notice = nil
    Task {
      defer { working = false }
      do {
        let release = try await Task.detached(priority: .userInitiated) {
          () -> MarketplaceRelease? in
          let archive = try BundleOperations.export(
            package, selections: entries, scope: scope, environment: runtime)
          if publishing {
            return try MarketplaceOperations.publishBundle(archive, to: destination)
          } else {
            try archive.write(to: destination, options: .atomic)
            return nil
          }
        }.value
        if let release { didPublish(release.origin) }
        notice =
          publishing
          ? "Published " + package.name + " " + package.version + " to " + destination.path
          : "Exported " + destination.lastPathComponent
      } catch {
        failure = String(describing: error)
      }
    }
  }
}
