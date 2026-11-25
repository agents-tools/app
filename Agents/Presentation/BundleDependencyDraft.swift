import AgentsCore
import Foundation

struct BundleDependencyDraft: Identifiable {
  let id = UUID()
  var package = ""
  var requirement = SourceRequirement.upToNextMajor(from: "")
  var usesGitCatalog = false
  var gitURL = ""
  var gitRef = ""
  var gitSubpath = ""

  func dependency() throws -> MarketplacePackageRequirement {
    let catalog =
      usesGitCatalog
      ? try MarketplaceOrigin(
        kind: .git, location: gitURL, ref: gitRef.isEmpty ? nil : gitRef,
        subpath: gitSubpath.isEmpty ? nil : gitSubpath
      )
      : nil
    return try MarketplacePackageRequirement(
      package: package, requirement: requirement, catalog: catalog)
  }
}
