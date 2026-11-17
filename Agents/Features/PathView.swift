import AppKit
import SwiftUI

struct PathView: View {
  let url: URL
  var scope: WorkspaceScope?

  var body: some View {
    Text(displayPath)
      .textSelection(.disabled)
      .lineLimit(1)
      .truncationMode(.middle)
      .help(url.path)
      .accessibilityLabel(Text(verbatim: url.path))
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
    Text(text).lineLimit(1).truncationMode(.middle).help(text)
      .contextMenu { Button("Copy Value") { copyText(text) } }
  }
}

/// Disclosure headers are buttons with their own literal label. Selectable detail text stays
/// inside the expanded content rather than participating in the header's inferred AX label.
struct DetailsGroup<Content: View>: View {
  let title: String
  let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    DisclosureGroup {
      content
    } label: {
      Text(verbatim: title)
    }
    .disclosureGroupStyle(DetailsStyle(title: title))
  }
}

private struct DetailsStyle: DisclosureGroupStyle {
  let title: String

  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        configuration.isExpanded.toggle()
      } label: {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption).accessibilityHidden(true)
          Text(verbatim: title).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .textSelection(.disabled)
      .accessibilityLabel(Text(verbatim: title))
      .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
      .help(title)
      .contextMenu { Button("Copy Heading") { copyText(title) } }
      if configuration.isExpanded {
        configuration.content.padding(.leading, 16)
      }
    }
  }
}
