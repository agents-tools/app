import AppKit
import SwiftUI

struct PathView: View {
  let url: URL
  var scope: WorkspaceScope?

  var body: some View {
    Text(displayPath)
      .lineLimit(1)
      .truncationMode(.middle)
      .help(url.path)
      .accessibilityLabel(url.path)
      .contextMenu { Button("Copy Full Path") { copyText(url.path) } }
  }

  private var displayPath: String {
    guard let scope else { return url.path }
    let root = scope.root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == root { return scope.kind == .user ? "~" : scope.root.lastPathComponent }
    if path.hasPrefix(root + "/") {
      return (scope.kind == .user ? "~" : ".") + path.dropFirst(root.count)
    }
    return path
  }
}

@MainActor
func copyText(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}

struct CompactText: View {
  let text: String
  var body: some View {
    Text(text).lineLimit(1).truncationMode(.middle).help(text).accessibilityLabel(text)
      .contextMenu { Button("Copy Value") { copyText(text) } }
  }
}
