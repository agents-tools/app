import AgentsCore
import AgentsUpdates
import AppKit
import SwiftUI

struct PackageInstallSheet: View {
  let scope: WorkspaceScope
  let environment: RuntimeEnvironment
  let preferences: AppPreferences
  let review: (UpdateProposal) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var origin: MarketplaceOrigin?
  @State private var releases: [MarketplaceRelease] = []
  @State private var pins: [MarketplacePin] = []
  @State private var query = ""
  @State private var selected: MarketplaceCoordinate?
  @State private var verified: VerifiedMarketplacePackage?
  @State private var bundle: BundleInspection?
  @State private var targets: [String: Set<AgentID>] = [:]
  @State private var alias = ""
  @State private var gitURL = ""
  @State private var editingGit = false
  @State private var busy = false
  @State private var errorText: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Install Package").font(.headline)
        Spacer()
        Menu("Marketplace") {
          ForEach(preferences.marketplaces, id: \.self) { remembered in
            Button(remembered.location) { browse(remembered) }
          }
          Divider()
          Button("Choose Directory…") { chooseDirectory() }
          Button("Add Git Repository…") { editingGit = true }
          if let origin {
            Button("Forget This Marketplace") {
              preferences.forget(origin)
              self.origin = nil
              releases = []
              clearPackage()
            }
          }
        }
        if !pins.isEmpty {
          Menu("Installed Packages") {
            ForEach(pins, id: \.dependency.name) { pin in
              Menu(pin.dependency.name + " · " + pin.dependency.coordinate.version) {
                Button("View Releases") { browse(pin.dependency.catalog) }
                Button("Review Removal…") {
                  review(
                    UpdateProposal(
                      id: UUID(), scope: scope, title: "Remove " + pin.dependency.name,
                      request: MarketplaceOperations.removalRequest(for: pin.dependency.name)))
                }
              }
            }
          }
        }
        Button("Open Bundle…") { openBundle() }
      }
      if let origin {
        Text(origin.location).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let bundle {
        Form {
          Section(bundle.package.name + " · " + bundle.package.version) {
            if let verified {
              TextField("Dependency name", text: $alias)
              if let pin = pins.first(where: { $0.dependency.name == alias }) {
                LabeledContent("Installed version", value: pin.dependency.coordinate.version)
              }
              LabeledContent("Selected version", value: verified.release.coordinate.version)
            }
            ForEach(bundle.components, id: \.id) { item in
              HStack {
                VStack(alignment: .leading) {
                  Text(item.name)
                  Text(DeclarationLabels.kind(item.kind.rawValue)).foregroundStyle(.secondary).font(
                    .caption)
                }
                Spacer()
                Menu(clientSummary(for: item)) {
                  ForEach(item.supportedTargets(in: scope.installScope), id: \.self) { agent in
                    Toggle(agent.displayName, isOn: targetBinding(item, agent))
                  }
                }
              }
            }
          }
        }.formStyle(.grouped)
      } else if origin != nil {
        TextField("Filter packages", text: $query)
        List(
          releases.filter {
            query.isEmpty || $0.coordinate.package.localizedCaseInsensitiveContains(query)
              || $0.summary?.localizedCaseInsensitiveContains(query) == true
          }, id: \.coordinate, selection: $selected
        ) { release in
          HStack {
            VStack(alignment: .leading) {
              Text(release.coordinate.package)
              if let summary = release.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            Text(release.coordinate.version).monospacedDigit()
          }.tag(release.coordinate)
        }
      } else {
        ContentUnavailableView("Choose a Marketplace or Bundle", systemImage: "shippingbox")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if let errorText { Text(errorText).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        if origin != nil && bundle != nil { Button("Back to Releases") { clearPackage() } }
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        if bundle != nil {
          Button("Review Installation…") { prepare() }
            .disabled(targets.values.allSatisfy(\.isEmpty) || (verified != nil && alias.isEmpty))
        } else if let release = releases.first(where: { $0.coordinate == selected }) {
          Button("Inspect Package") { inspect(release) }
        }
      }
    }.padding(18).frame(minWidth: 640, minHeight: 480).disabled(busy).interactiveDismissDisabled(
      busy
    )
    .task {
      let runtime = environment
      let selectedScope = scope.installScope
      do {
        pins = try await Task.detached {
          try MarketplaceOperations.installed(scope: selectedScope, environment: runtime)
        }.value
      } catch {
        errorText = String(describing: error)
        return
      }
      if let first = preferences.marketplaces.first { browse(first) }
    }
    .alert("Add Git Marketplace", isPresented: $editingGit) {
      TextField("Repository URL", text: $gitURL)
      Button("Cancel", role: .cancel) {}
      Button("Browse") {
        do { browse(try MarketplaceOrigin(kind: .git, location: gitURL)) } catch {
          errorText = String(describing: error)
        }
      }
    }
  }

  private func clearPackage() {
    bundle = nil
    verified = nil
    selected = nil
    targets = [:]
    errorText = nil
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { browse(try MarketplaceOrigin(kind: .directory, location: url.path)) } catch {
      errorText = String(describing: error)
    }
  }

  private func browse(_ source: MarketplaceOrigin) {
    clearPackage()
    releases = []
    origin = source
    run {
      let registration = try MarketplaceRegistration(name: "team", origin: source)
      return try MarketplaceOperations.browse(
        registration, scope: scope.installScope, environment: environment)
    } receive: { catalog in
      preferences.remember(source)
      releases = catalog.releases
    }
  }

  private func openBundle() {
    let panel = NSOpenPanel()
    guard panel.runModal() == .OK, let file = panel.url else { return }
    run {
      try BundleOperations.inspect(Data(contentsOf: file))
    } receive: { contents in
      origin = nil
      clearPackage()
      bundle = contents
    }
  }

  private func inspect(_ release: MarketplaceRelease) {
    run {
      let package = try MarketplaceOperations.acquire(
        release, scope: scope.installScope, environment: environment)
      let contents = try package.inspectBundle()
      let components = try UpdateOperations.inspect(
        scope: scope.installScope, environment: environment
      ).components
      return (package, contents, components)
    } receive: { package, contents, current in
      verified = package
      bundle = contents
      let installed = pins.first {
        $0.dependency.catalog == release.origin
          && $0.dependency.coordinate.package == contents.package.name
      }
      alias = installed?.dependency.name ?? contents.package.name
      if let installed {
        let existing = current.filter { installed.componentRecords.contains($0.record) }
        for item in contents.components {
          let matches = existing.filter { $0.kind == item.kind && $0.name == item.name }
          if matches.count == 1, let match = matches.first {
            targets[item.id] = Set(match.recipients).intersection(
              item.supportedTargets(in: scope.installScope))
          }
        }
      }
    }
  }

  private func prepare() {
    guard let bundle else { return }
    let package = verified
    let name = alias
    let selections = bundle.components.compactMap { item -> BundleImportSelection? in
      guard let choices = targets[item.id], !choices.isEmpty else { return nil }
      return BundleImportSelection(
        componentID: item.id, targets: AgentID.allCases.filter(choices.contains))
    }
    run {
      if let package {
        return try package.previewImport(
          as: name, selections: selections, scope: scope.installScope, environment: environment)
      }
      return try BundleOperations.previewImport(
        bundle, selections: selections, scope: scope.installScope, environment: environment)
    } receive: { preview in
      if let conflict = preview.ownershipConflict {
        errorText = conflict
      } else {
        review(UpdateProposal(scope: scope, bundle: preview))
      }
    }
  }

  private func clientSummary(for item: BundleComponent) -> String {
    let clients = AgentID.allCases.filter { targets[item.id]?.contains($0) == true }
    return clients.isEmpty ? "Choose Clients" : clients.map(\.displayName).joined(separator: ", ")
  }

  private func targetBinding(_ item: BundleComponent, _ agent: AgentID) -> Binding<Bool> {
    Binding(
      get: { targets[item.id]?.contains(agent) == true },
      set: { enabled in
        if enabled {
          targets[item.id, default: []].insert(agent)
        } else {
          targets[item.id]?.remove(agent)
        }
      })
  }

  private func run<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T, receive: @escaping (T) -> Void
  ) {
    guard !busy else { return }
    busy = true
    errorText = nil
    Task {
      defer { busy = false }
      do { receive(try await Task.detached(priority: .userInitiated, operation: work).value) } catch
      { errorText = String(describing: error) }
    }
  }
}
