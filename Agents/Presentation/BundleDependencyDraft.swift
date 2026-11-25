import AgentsCore
import Foundation

struct BundleDependencyDraft: Identifiable {
  let id = UUID()
  var package = ""
  var requirement = SourceRequirement.upToNextMajor(from: "")
  enum CatalogSource: Hashable { case publishing, git, hosted }
  var source: CatalogSource = .publishing
  var indexURL = ""
  var gitURL = ""
  var gitRef = ""
  var gitSubpath = ""

  func dependency() throws -> MarketplacePackageRequirement {
    let catalog: MarketplaceOrigin?
    switch source {
    case .publishing:
      catalog = nil
    case .git:
      catalog = try MarketplaceOrigin(
        kind: .git, location: gitURL, ref: gitRef.isEmpty ? nil : gitRef,
        subpath: gitSubpath.isEmpty ? nil : gitSubpath)
    case .hosted:
      catalog = try MarketplaceOrigin(kind: .hosted, location: indexURL)
    }
    return try MarketplacePackageRequirement(
      package: package, requirement: requirement, catalog: catalog)
  }
}
