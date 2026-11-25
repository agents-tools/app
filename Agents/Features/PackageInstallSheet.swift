import AgentsCore
import AgentsUpdates
import AppKit
import SwiftUI

struct PackageInstallSheet: View {
  let scope: WorkspaceScope
  let environment: RuntimeEnvironment
  let review: (UpdateProposal) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var registrations: [RegisteredMarketplace] = []
  @State private var registrationName = ""
  @State private var savingMarketplace = false
  @State private var selectedRegistration: RegisteredMarketplace?
  @State private var origin: MarketplaceOrigin?
  @State private var releases: [MarketplaceRelease] = []
  @State private var pins: [MarketplacePin] = []
  @State private var query = ""
  @State private var selected: MarketplaceCoordinate?
  @State private var verified: VerifiedMarketplacePackage?
  @State private var bundle: BundleInspection?
  @State private var targets: [String: Set<AgentID>] = [:]
  @State private var alias = ""
  @State private var updatingPin: MarketplacePin?
  @State private var gitURL = ""
  @State private var gitRef = ""
  @State private var gitSubpath = ""
  @State private var editingGit = false
  @State private var busy = false
  @State private var errorText: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Packages").font(.headline)
        Spacer()
        Menu("Marketplace") {
          ForEach(registrations, id: \.registration.name) { entry in
            Button(entry.registration.name + " · " + entry.scope.rawValue.capitalized) {
              browse(entry.registration.origin, registered: entry)
            }
          }
          if !registrations.isEmpty { Divider() }
          Button("Choose Directory…") { chooseDirectory() }
          Button("Browse Git Repository…") { editingGit = true }
          if let entry = selectedRegistration {
            if entry.scope == scope.installScope {
              Button("Forget “" + entry.registration.name + "”") { forget(entry) }
            }
          } else if origin != nil {
            Button("Save Marketplace As…") {
              registrationName = ""
              savingMarketplace = true
            }
          }
        }
        if !pins.isEmpty {
          Menu("Installed Packages") {
            ForEach(pins, id: \.dependency.name) { pin in
              Menu(pin.dependency.name + " · " + pin.dependency.coordinate.version) {
                Button("Check for Updates") { checkUpdates(for: pin) }
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
        if let updatingPin {
          LabeledContent(
            "Installed",
            value: updatingPin.dependency.name + " · " + updatingPin.dependency.coordinate.version)
        } else {
          TextField("Filter packages", text: $query)
        }
        if updatingPin != nil && releases.isEmpty && !busy && errorText == nil {
          ContentUnavailableView("No Newer Releases", systemImage: "checkmark.circle")
        } else {
          List(
            releases.filter {
              updatingPin != nil || query.isEmpty
                || $0.coordinate.package.localizedCaseInsensitiveContains(query)
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
          Button(updatingPin == nil ? "Review Installation…" : "Review Update…") { prepare() }
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
        let values = try await Task.detached {
          try (
            MarketplaceDirectory.list(scope: selectedScope, environment: runtime),
            MarketplaceOperations.installed(scope: selectedScope, environment: runtime)
          )
        }.value
        registrations = values.0
        pins = values.1
      } catch {
        errorText = String(describing: error)
        return
      }
    }
    .alert("Save Marketplace", isPresented: $savingMarketplace) {
      TextField("Marketplace name", text: $registrationName)
      Button("Cancel", role: .cancel) {}
      Button("Save") { saveMarketplace() }.disabled(registrationName.isEmpty)
    } message: {
      Text("Save in " + scope.installScope.rawValue + " configuration.")
    }
    .sheet(isPresented: $editingGit) {
      VStack(alignment: .leading) {
        Text("Add Git Marketplace").font(.headline)
        Form {
          TextField("Repository URL", text: $gitURL)
          TextField("Branch, tag or commit", text: $gitRef, prompt: Text("Default branch"))
          TextField("Catalog directory", text: $gitSubpath, prompt: Text("Repository root"))
        }
        HStack {
          Button("Cancel") { editingGit = false }.keyboardShortcut(.cancelAction)
          Spacer()
          Button("Browse") {
            editingGit = false
            do {
              browse(
                try MarketplaceOrigin(
                  kind: .git, location: gitURL,
                  ref: gitRef.isEmpty ? nil : gitRef, subpath: gitSubpath.isEmpty ? nil : gitSubpath
                ))
            } catch { errorText = String(describing: error) }
          }.keyboardShortcut(.defaultAction).disabled(gitURL.isEmpty)
        }
      }.padding().frame(minWidth: 420)
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
    var location = url.standardizedFileURL.path
    let base = scope.root.standardizedFileURL.path
    if scope.installScope == .project, location == base || location.hasPrefix(base + "/") {
      let relative = String(location.dropFirst(base.count).drop(while: { $0 == "/" }))
      location = relative.isEmpty ? "." : relative
    }
    do { browse(try MarketplaceOrigin(kind: .directory, location: location)) } catch {
      errorText = String(describing: error)
    }
  }

  private func checkUpdates(for pin: MarketplacePin) {
    clearPackage()
    releases = []
    origin = pin.dependency.catalog
    selectedRegistration = nil
    updatingPin = pin
    run {
      try MarketplaceOperations.availableUpdates(
        for: pin, scope: scope.installScope, environment: environment)
    } receive: { updates in
      releases = updates
      selected = updates.first?.coordinate
    }
  }

  private func saveMarketplace() {
    guard let origin else { return }
    let name = registrationName
    run {
      let entry = try MarketplaceRegistration(name: name, origin: origin)
      try MarketplaceDirectory.register(entry, scope: scope.installScope, environment: environment)
      return try MarketplaceDirectory.list(scope: scope.installScope, environment: environment)
    } receive: { entries in
      registrations = entries
      selectedRegistration = entries.first { $0.registration.name == name }
      self.origin = selectedRegistration?.registration.origin
    }
  }

  private func forget(_ entry: RegisteredMarketplace) {
    run {
      try MarketplaceDirectory.unregister(
        entry.registration.name, scope: scope.installScope, environment: environment)
      return try MarketplaceDirectory.list(scope: scope.installScope, environment: environment)
    } receive: { entries in
      registrations = entries
      selectedRegistration = nil
      origin = nil
      releases = []
      updatingPin = nil
      clearPackage()
    }
  }

  private func browse(_ source: MarketplaceOrigin, registered: RegisteredMarketplace? = nil) {
    selectedRegistration = registered
    updatingPin = nil
    clearPackage()
    releases = []
    origin = source
    run {
      let registration = try MarketplaceRegistration(name: "team", origin: source)
      return try MarketplaceOperations.browse(
        registration, scope: scope.installScope, environment: environment)
    } receive: { catalog in
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
      selectedRegistration = nil
      updatingPin = nil
      clearPackage()
      bundle = contents
    }
  }

  private func inspect(_ release: MarketplaceRelease) {
    let selectedPin = updatingPin
    run {
      let package = try MarketplaceOperations.acquire(
        release, scope: scope.installScope, environment: environment)
      let contents = try package.inspectBundle()
      let inspection = try UpdateOperations.inspect(
        scope: scope.installScope, environment: environment)
      let matches = inspection.marketplacePackages.filter {
        $0.dependency.catalog == release.origin
          && $0.dependency.coordinate.package == contents.package.name
      }
      let installed = selectedPin ?? (matches.count == 1 ? matches.first : nil)
      let selections =
        try installed.map { try contents.retainedSelections(for: $0, in: inspection) } ?? []
      return (package, contents, installed, selections)
    } receive: { package, contents, installed, selections in
      verified = package
      bundle = contents
      alias = installed?.dependency.name ?? contents.package.name
      targets = Dictionary(
        uniqueKeysWithValues: selections.map { ($0.componentID, Set($0.targets)) })
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
