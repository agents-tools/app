import AgentsCore
import AgentsUpdates
import AppKit
import SwiftUI

struct BundleAuthoringSheet: View {
  let snapshot: WorkspaceSnapshot
  let environment: RuntimeEnvironment

  @Environment(\.dismiss) private var dismiss
  @State private var selection = Set<String>()
  @State private var name = ""
  @State private var version = "1.0.0"
  @State private var dependencies: [BundleDependencyDraft] = []
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
      Form {
        Section("Package") {
          TextField("Package name", text: $name)
          TextField("Version", text: $version)
        }
        Section("Bundle Components") {
          ForEach(components, id: \.record) { component in
            Toggle(
              isOn: Binding(
                get: { selection.contains(component.record) },
                set: {
                  if $0 {
                    selection.insert(component.record)
                  } else {
                    selection.remove(component.record)
                  }
                }
              )
            ) {
              VStack(alignment: .leading) {
                Text(component.name)
                Text(DeclarationLabels.kind(component.kind.rawValue) + " · " + component.source)
                  .font(.caption).foregroundStyle(.secondary)
                  .lineLimit(1).truncationMode(.middle).help(component.source)
              }
            }
          }
        }
        Section("Package Dependencies") {
          ForEach($dependencies) { $dependency in
            BundleDependencyRow(dependency: $dependency) {
              let id = dependency.id
              dependencies.removeAll { $0.id == id }
            }
          }
          Button("Add Dependency", systemImage: "plus") { dependencies.append(.init()) }
        }
      }.formStyle(.grouped)
      if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
      if let notice { Text(notice).textSelection(.enabled) }
      HStack {
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if working { ProgressView().controlSize(.small) }
        Button("Export File…") { chooseDestination(publishing: false) }.disabled(!ready)
        Button("Publish to Marketplace…") { chooseDestination(publishing: true) }.disabled(!ready)
      }
    }.padding(20).frame(minWidth: 580, minHeight: 500)
      .disabled(working).interactiveDismissDisabled(working)
  }

  private var ready: Bool { !selection.isEmpty && !name.isEmpty && !version.isEmpty && !working }

  private func chooseDestination(publishing: Bool) {
    let package: BundlePackage
    do {
      let requirements = try dependencies.map { try $0.dependency() }
      if publishing || !requirements.isEmpty {
        _ = try MarketplaceCoordinate(package: name, version: version)
      }
      package = BundlePackage(name: name, version: version, dependencies: requirements)
    } catch {
      failure = String(describing: error)
      return
    }
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
    let entries = components.filter { selection.contains($0.record) }.map(\.selection)
    let scope = snapshot.scope.installScope
    let runtime = environment
    working = true
    failure = nil
    notice = nil
    Task {
      defer { working = false }
      do {
        try await Task.detached(priority: .userInitiated) {
          let archive = try BundleOperations.export(
            package, selections: entries, scope: scope, environment: runtime)
          if publishing {
            _ = try MarketplaceOperations.publishBundle(archive, to: destination)
          } else {
            try archive.write(to: destination, options: .atomic)
          }
        }.value
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

private struct BundleDependencyRow: View {
  @Binding var dependency: BundleDependencyDraft
  let remove: () -> Void
  @State private var expanded = true

  var body: some View {
    DisclosureGroup(
      dependency.package.isEmpty ? "New Dependency" : dependency.package, isExpanded: $expanded
    ) {
      TextField("Package name", text: $dependency.package)
      PackageRequirementEditor(requirement: $dependency.requirement)
      Picker("Marketplace", selection: $dependency.source) {
        Text("Publishing Marketplace").tag(BundleDependencyDraft.CatalogSource.publishing)
        Text("Git Repository").tag(BundleDependencyDraft.CatalogSource.git)
        Text("HTTPS Index").tag(BundleDependencyDraft.CatalogSource.hosted)
      }
      if dependency.source == .hosted {
        TextField("Index URL", text: $dependency.indexURL)
      } else if dependency.source == .git {
        TextField("Repository URL", text: $dependency.gitURL)
        TextField("Branch, tag or commit", text: $dependency.gitRef, prompt: Text("Default branch"))
        TextField(
          "Catalog directory", text: $dependency.gitSubpath, prompt: Text("Repository root"))
      }
      Button("Remove Dependency", role: .destructive, action: remove)
    }
  }
}
