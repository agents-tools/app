import AgentsCore
import AgentsUpdates
import AppKit
import SwiftUI

struct PackageInstallSheet: View {
  let model: AppModel
  let scope: WorkspaceScope
  let environment: RuntimeEnvironment
  let review: (UpdateProposal) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var registrations: [RegisteredMarketplace] = []
  @State private var registrationName = ""
  @State private var savingMarketplace = false
  @State private var showingVerification = false
  @State private var selectedRegistration: RegisteredMarketplace?
  @State private var origin: MarketplaceOrigin?
  @State private var releases: [MarketplaceRelease] = []
  @State private var pins: [MarketplacePin] = []
  @State private var installedGraph: MarketplaceGraph?
  @State private var hasDeclaredPackages = false
  @State private var pendingDeployment: MarketplacePendingDeployment?
  @State private var lockReview: LifecyclePackageReview<MarketplaceLockPreview, MarketplaceLockReport>?
  @State private var savingLock = false
  @State private var query = ""
  @State private var selected: MarketplaceCoordinate?
  @State private var verified: VerifiedMarketplacePackage?
  @State private var bundle: BundleInspection?
  @State private var graphDraft: MarketplacePackageDraft?
  @State private var targets: [String: Set<AgentID>] = [:]
  @State private var alias = ""
  @State private var updatingPin: MarketplacePin?
  @State private var gitURL = ""
  @State private var gitRef = ""
  @State private var gitSubpath = ""
  @State private var editingGit = false
  @State private var editingHosted = false
  @State private var editingCredential = false
  @State private var hostedTokens: [URL: String] = [:]
  @State private var userHostedIndices: Set<URL> = []
  @State private var downloadOrigins: [URL] = []
  @State private var editingOrigins = false
  @State private var busy = false
  @State private var errorText: String?

  private var replacesBundlePin: Bool {
    verified != nil && pins.contains { $0.dependency.name == alias }
  }

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
          if hasDeclaredPackages || installedGraph != nil || pendingDeployment != nil {
            Button("Review Declared Package Lock…") {
              runWithMarketAccess { access in
                try MarketplaceOperations.previewLockOnlyLifecycle(
                  .reconcile, intent: .update, scope: scope.installScope,
                  environment: environment, hostedAccess: access)
              } receive: { preview in
                lockReview = preview
                savingLock = true
              }
            }
          }
          Button("Choose Directory…") { chooseDirectory() }
          Button("Browse Git Repository…") { editingGit = true }
          Button("Add HTTPS Marketplace…") { editingHosted = true }
          if let origin {
            if origin.hostedIndex != nil {
              Button("Trusted Download Origins…") { editingOrigins = true }
            }
            if let index = origin.hostedIndex, userHostedIndices.contains(index) {
              Button("Set Access Token…") { editingCredential = true }
            }
            Button("Verify All Releases") {
              browse(origin, registered: selectedRegistration, verify: true)
            }
            .disabled(busy)
          }
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
        if !pins.isEmpty || installedGraph?.roots.isEmpty == false {
          Menu("Installed Packages") {
            if let graph = installedGraph {
              ForEach(graph.roots, id: \.intent.name) { root in
                let version = graph.nodes.first { $0.id == root.node }?.coordinate.version
                Menu(root.intent.name + (version.map { " · " + $0 } ?? "")) {
                  Button("Check for Updates") {
                    clearPackage()
                    releases = []
                    origin = root.intent.catalog
                    selectedRegistration = nil
                    updatingPin = nil
                    showGraph(.init(upgrading: root.intent))
                  }
                  Button("Review Removal…") { reviewRemoval(root.intent.name) }
                }
              }
            }
            ForEach(pins, id: \.dependency.name) { pin in
              Menu(pin.dependency.name + " · " + pin.dependency.coordinate.version) {
                Button("Check for Updates") { checkUpdates(for: pin) }
                Button("Review Removal…") {
                  review(
                    UpdateProposal(
                      id: UUID(), scope: scope, title: "Remove " + pin.dependency.name,
                      request: MarketplaceOperations.removalRequest(for: pin.dependency.name),
                      intent: .uninstall))
                }
              }
            }
          }
        }
        Button("Open Bundle…") { openBundle() }
      }
      if let pendingDeployment {
        HStack {
          Label("Package lock awaiting deployment", systemImage: "clock")
          Spacer()
          Button("Review Offline Deployment…") {
            run {
              try MarketplaceOperations.previewFrozenLifecycle(
                intent: .install, scope: scope.installScope, environment: environment)
            } receive: { preview in
              if let conflict = preview.ownershipConflict {
                errorText = conflict
              } else {
                review(UpdateProposal(
                  scope: scope, title: "Deploy Locked Packages",
                  packageReview: .init(preview, scope: scope, report: \.self)))
              }
            }
          }
        }
        .help(pendingDeployment.digest)
      }
      if let origin {
        Text(origin.location).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let draft = Binding($graphDraft) {
        MarketplaceSelectionView(
          draft: draft, errorText: $errorText, scope: scope.installScope, resolve: resolveGraph)
      } else if let bundle {
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
              PackageClientPicker(
                component: item, scope: scope.installScope,
                targets: Binding(
                  get: { targets[item.id] ?? [] },
                  set: { targets[item.id] = $0 }
                )
              )
              .disabled(bundle.package.dependencies != nil)
            }
            if bundle.package.dependencies != nil {
              Text("Publish this bundle to a marketplace to resolve and install its dependencies.")
                .font(.caption).foregroundStyle(.secondary)
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
        if !releases.isEmpty && (bundle != nil || graphDraft != nil) {
          Button("Back to Releases") { clearPackage() }
        }
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        if let graphDraft {
          Button("Save to Lock…") {
            runWithMarketAccess { access in
              try graphDraft.previewLock(scope: scope.installScope, environment: environment, hostedAccess: access)
            } receive: { preview in
              lockReview = preview
              savingLock = true
            }
          }.disabled(!graphDraft.canReview(in: scope.installScope))
          Button(graphDraft.installed == nil ? "Review Installation…" : "Review Update…") {
            prepareGraph(graphDraft)
          }.disabled(pendingDeployment != nil || !graphDraft.canReview(in: scope.installScope))
        } else if let bundle {
          Button(replacesBundlePin ? "Review Update…" : "Review Installation…") { prepare() }
            .disabled(
              bundle.package.dependencies != nil || targets.values.allSatisfy(\.isEmpty)
                || (verified != nil && alias.isEmpty))
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
            UpdateOperations.inspect(scope: selectedScope, environment: runtime),
            Set(MarketplaceDirectory.list(scope: .user, environment: runtime).compactMap {
              $0.registration.origin.hostedIndex
            })
          )
        }.value
        registrations = values.0
        userHostedIndices = values.2
        pins = values.1.marketplacePackages
        installedGraph = values.1.marketplaceGraph
        pendingDeployment = values.1.pendingMarketplaceDeployment
        hasDeclaredPackages = values.1.declaration?.marketplaceRoots.isEmpty == false
      } catch {
        errorText = String(describing: error)
        return
      }
    }
    .alert("Marketplace Verified", isPresented: $showingVerification) {
      Button("Done") {}
    } message: {
      Text("Verified releases: \(releases.count)")
    }
    .alert("Save Marketplace", isPresented: $savingMarketplace) {
      TextField("Marketplace name", text: $registrationName)
      Button("Cancel", role: .cancel) {}
      Button("Save") { saveMarketplace() }.disabled(registrationName.isEmpty)
    } message: {
      Text("Save in " + scope.installScope.rawValue + " configuration.")
    }
    .sheet(isPresented: $savingLock, onDismiss: { lockReview = nil }) {
      if let lockReview {
        MarketplaceLockReview(model: model, scope: scope, review: lockReview) { saved in
          pendingDeployment = saved.pendingDeployment
          clearPackage()
        }
      }
    }
    .sheet(isPresented: $editingOrigins) {
      HostedDownloadOriginsForm(origins: downloadOrigins) { origins in
        downloadOrigins = origins
        editingOrigins = false
        if let origin { browse(origin, registered: selectedRegistration) }
      }
    }
    .sheet(isPresented: $editingHosted) {
      HostedMarketplaceForm(index: nil, allowsToken: scope.installScope == .user) { name, origin, token in
        editingHosted = false
        storeMarketplace(name: name, origin: origin, token: token, connect: true)
      }
    }
    .sheet(isPresented: $editingCredential) {
      if let origin, let index = origin.hostedIndex {
        HostedMarketplaceForm(index: index, allowsToken: true) { _, _, token in
          editingCredential = false
          hostedTokens[index] = token
          browse(origin, registered: selectedRegistration)
        }
      }
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
    graphDraft = nil
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
    runWithMarketAccess { access in
      let registration = try MarketplaceRegistration(name: pin.dependency.name, origin: pin.dependency.catalog)
      return try MarketplaceOperations.browse(
        registration, scope: scope.installScope, environment: environment, hostedAccess: access
      ).updates(for: pin)
    } receive: { updates in
      releases = updates
      selected = updates.first?.coordinate
    }
  }

  private func saveMarketplace() {
    guard let origin else { return }
    storeMarketplace(name: registrationName, origin: origin, token: nil, connect: false)
  }

  private func storeMarketplace(name: String, origin: MarketplaceOrigin, token: String?, connect: Bool) {
    run {
      let entry = try MarketplaceRegistration(name: name, origin: origin)
      try MarketplaceDirectory.register(entry, scope: scope.installScope, environment: environment)
      return try MarketplaceDirectory.list(scope: scope.installScope, environment: environment)
    } receive: { entries in
      registrations = entries
      selectedRegistration = entries.first { $0.registration.name == name }
      self.origin = selectedRegistration?.registration.origin
      if scope.installScope == .user, let index = origin.hostedIndex {
        userHostedIndices.insert(index)
        if let token { hostedTokens[index] = token }
      }
      if connect { browse(origin, registered: selectedRegistration) }
    }
  }

  private func forget(_ entry: RegisteredMarketplace) {
    run {
      try MarketplaceDirectory.unregister(
        entry.registration.name, scope: scope.installScope, environment: environment)
      return try MarketplaceDirectory.list(scope: scope.installScope, environment: environment)
    } receive: { entries in
      registrations = entries
      if entry.scope == .user, let index = entry.registration.origin.hostedIndex,
        !entries.contains(where: { $0.scope == .user && $0.registration.origin.hostedIndex == index })
      {
        userHostedIndices.remove(index)
        hostedTokens[index] = nil
      }
      selectedRegistration = nil
      origin = nil
      releases = []
      updatingPin = nil
      clearPackage()
    }
  }

  private func browse(
    _ source: MarketplaceOrigin, registered: RegisteredMarketplace? = nil, verify: Bool = false
  ) {
    guard !busy else { return }
    selectedRegistration = registered
    updatingPin = nil
    clearPackage()
    releases = []
    origin = source
    runWithMarketAccess { access in
      let registration =
        try registered?.registration
        ?? MarketplaceRegistration(name: "team", origin: source)
      if verify {
        return try MarketplaceOperations.verifyCatalog(
          registration, scope: scope.installScope, environment: environment, hostedAccess: access)
      }
      return try MarketplaceOperations.browse(
        registration, scope: scope.installScope, environment: environment, hostedAccess: access)
    } receive: { catalog in
      releases = catalog.releases
      showingVerification = verify
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
      releases = []
      clearPackage()
      bundle = contents
    }
  }

  private enum InspectedRelease: Sendable {
    case graph(MarketplacePackageDraft)
    case legacy(
      VerifiedMarketplacePackage, BundleInspection, MarketplacePin, [BundleImportSelection])
  }

  private func inspect(_ release: MarketplaceRelease) {
    let selectedPin = updatingPin
    runWithMarketAccess { access -> InspectedRelease in
      let inspection = try UpdateOperations.inspect(
        scope: scope.installScope, environment: environment)
      let roots =
        inspection.marketplaceGraph?.roots.filter {
          $0.intent.catalog == release.origin && $0.intent.package == release.coordinate.package
        } ?? []
      if selectedPin == nil, roots.count == 1, let root = roots.first {
        return .graph(.init(upgrading: root.intent, to: release.coordinate.version))
      }
      let matches = inspection.marketplacePackages.filter {
        $0.dependency.catalog == release.origin
          && $0.dependency.coordinate.package == release.coordinate.package
      }
      guard let legacy = selectedPin ?? (matches.count == 1 ? matches.first : nil) else {
        return .graph(.init(release: release))
      }
      let package = try MarketplaceOperations.acquire(
        release, scope: scope.installScope, environment: environment, hostedAccess: access)
      let contents = try package.inspectBundle()
      if contents.package.dependencies != nil {
        return .graph(.init(release: release, legacy: legacy))
      }
      return .legacy(
        package, contents, legacy, try contents.retainedSelections(for: legacy, in: inspection))
    } receive: { result in
      switch result {
      case .graph(let draft):
        showGraph(draft)
      case .legacy(let package, let contents, let installed, let selections):
        verified = package
        bundle = contents
        alias = installed.dependency.name
        targets = Dictionary(
          uniqueKeysWithValues: selections.map { ($0.componentID, Set($0.targets)) })
      }
    }
  }

  private func showGraph(_ draft: MarketplacePackageDraft) {
    graphDraft = draft
    resolveGraph()
  }

  private func resolveGraph() {
    guard let draft = graphDraft else { return }
    if draft.installed == nil
      && (pins.contains { $0.dependency.name == draft.name }
        || installedGraph?.roots.contains { $0.intent.name == draft.name } == true)
    {
      errorText = "That package alias is already installed. Choose another name."
      return
    }
    let resolvingPending = pendingDeployment != nil
    runWithMarketAccess { access in
      let request = try draft.request()
      if resolvingPending {
        return try MarketplaceOperations.previewLockOnly(request, scope: scope.installScope, environment: environment, hostedAccess: access).resolution
      }
      return try MarketplaceOperations.resolve(
        request, scope: scope.installScope, environment: environment, hostedAccess: access)
    } receive: { resolution in
      graphDraft?.capture(resolution)
    }
  }

  private func prepareGraph(_ draft: MarketplacePackageDraft) {
    runWithMarketAccess { access in
      try draft.preview(scope: scope.installScope, environment: environment, hostedAccess: access)
    } receive: { preview in
      review(UpdateProposal(
        scope: scope, title: draft.title, packageReview: .init(preview, scope: scope, report: \.report)))
    }
  }

  private func reviewRemoval(_ name: String) {
    runWithMarketAccess { access in
      try MarketplaceOperations.previewResolutionLifecycle(
        .remove(name), intent: .uninstall, scope: scope.installScope, environment: environment,
        hostedAccess: access)
    } receive: { preview in
      review(UpdateProposal(
        scope: scope, title: "Remove " + name, packageReview: .init(preview, scope: scope, report: \.report)))
    }
  }

  private func prepare() {
    guard let bundle else { return }
    let package = verified
    let name = alias
    let replacing = replacesBundlePin
    let intent: LifecycleOperationIntent = replacing ? .update : .install
    let selections = bundle.components.compactMap { item -> BundleImportSelection? in
      guard let choices = targets[item.id], !choices.isEmpty else { return nil }
      return BundleImportSelection(
        componentID: item.id, targets: AgentID.allCases.filter(choices.contains))
    }
    run {
      if let package {
        return try package.previewImportLifecycle(
          as: name, selections: selections, intent: intent, scope: scope.installScope,
          environment: environment)
      }
      return try BundleOperations.previewImportLifecycle(
        bundle, selections: selections, intent: intent, scope: scope.installScope,
        environment: environment)
    } receive: { preview in
      if let conflict = preview.ownershipConflict {
        errorText = conflict
      } else {
        let changes = preview.report.report.marketplaceChanges ?? []
        let replacesInstalledPackage = changes.contains { $0.before != nil && $0.after != nil }
        guard package == nil || replacing == replacesInstalledPackage || changes.isEmpty else {
          errorText = "The installed package changed. Reopen Packages and review it again."
          return
        }
        let title = (replacing ? "Update " : "Install ") + bundle.package.name + " "
          + bundle.package.version
        review(UpdateProposal(
          scope: scope, title: title, packageReview: .init(preview, scope: scope, report: \.report)))
      }
    }
  }

  private func runWithMarketAccess<T: Sendable>(
    _ work: @escaping @Sendable (HostedMarketplaceAccess) throws -> T, receive: @escaping (T) -> Void
  ) {
    let tokens = hostedTokens
    let origins = downloadOrigins
    run {
      try work(HostedMarketplaceAccess(trustedDownloadOrigins: origins, credentialProvider: { tokens[$0] }))
    } receive: { receive($0) }
  }

  private func run<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T, receive: @escaping (T) -> Void
  ) {
    guard !busy else { return }
    busy = true
    errorText = nil
    Task {
      do {
        let value = try await Task.detached(priority: .userInitiated, operation: work).value
        busy = false
        receive(value)
      } catch {
        busy = false
        errorText = String(describing: error)
      }
    }
  }
}
