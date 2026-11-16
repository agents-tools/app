import Foundation

struct ProjectRootUnavailable: Error, Sendable {
  let root: URL
  let reason: String
  var message: String {
    "The registered project directory is unavailable. Restore it or add its new location. " + reason
  }
}

/// An observation for presentation and rejecting known-unavailable requests. Core must still own
/// root identity/existence preconditions through publication; this check cannot close that race.
enum ProjectRootAccess {
  static func requireAvailable(_ scope: WorkspaceScope) throws {
    guard scope.kind == .project else { return }
    do {
      let url = URL(fileURLWithPath: scope.root.path, isDirectory: true)
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
      guard values.isDirectory == true else {
        throw ProjectRootUnavailable(root: scope.root, reason: "The location is not a directory.")
      }
      guard values.isReadable == true else {
        throw ProjectRootUnavailable(root: scope.root, reason: "The directory cannot be read.")
      }
    } catch let issue as ProjectRootUnavailable {
      throw issue
    } catch {
      throw ProjectRootUnavailable(root: scope.root, reason: error.localizedDescription)
    }
  }
}
