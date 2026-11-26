import AgentsInstructions
import AppKit
import SwiftUI

struct InstructionBuildBrowser: View {
  let outputs: [InstructionBuildOutput]
  let scope: WorkspaceScope

  @State private var selection: String?
  @State private var copied: Bool?

  private var selectedOutput: InstructionBuildOutput? {
    outputs.first { $0.id == selection } ?? outputs.first
  }

  var body: some View {
    if let output = selectedOutput {
      HSplitView {
        List(outputs, id: \.id, selection: $selection) { row in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: row.recipient.displayName)
              if row.fileURL != nil {
                Text(verbatim: row.displayName).font(.caption).foregroundStyle(.secondary)
              }
            }
            .lineLimit(1)
          } icon: {
            Image(systemName: row.fileURL == nil ? "doc.on.clipboard" : "doc.text")
          }
          .help(row.displayName)
          .tag(row.id)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160, idealWidth: 190, maxWidth: 250)
        .accessibilityIdentifier("instructions.build.outputs")

        detail(output)
          .frame(minWidth: 310, maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(height: 340)
      .onChange(of: outputs.map(\.id), initial: true) { _, ids in
        if selection.map(ids.contains) != true { selection = ids.first }
      }
      .onChange(of: selection) { copied = nil }
    } else {
      Text("No instructions were built.").foregroundStyle(.secondary)
    }
  }

  private func detail(_ output: InstructionBuildOutput) -> some View {
    let text = output.fullText
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: output.recipient.displayName).font(.headline)
          if let url = output.fileURL {
            PathView(url: url, scope: scope).font(.caption)
          } else {
            Text("Copy Only").font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 8)
        Button {
          if let text { copied = copyText(text) }
        } label: {
          Label(
            copied == true ? "Copied" : "Copy Full Text",
            systemImage: copied == true ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .disabled(text == nil)
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .accessibilityIdentifier("instructions.build.copy")
      }
      if copied == false {
        Text("Couldn’t write to the clipboard.").font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      if let text {
        CompiledInstructionText(text: text)
          .id(output.id)
      } else {
        Text("The output is not UTF-8 text.").foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
    }
    .padding(10)
  }
}

private struct CompiledInstructionText: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    if let view = scrollView.documentView as? NSTextView {
      view.isEditable = false
      view.isSelectable = true
      view.isRichText = false
      view.usesFindBar = true
      view.isIncrementalSearchingEnabled = true
      view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      view.textContainerInset = NSSize(width: 5, height: 8)
      view.setAccessibilityLabel("Compiled instruction text")
      view.setAccessibilityIdentifier("instructions.build.text")
    }
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    if let view = scrollView.documentView as? NSTextView, view.string != text {
      view.string = text
      view.scrollToBeginningOfDocument(nil)
    }
  }
}

extension InstructionBuildOutput {
  var fullText: String? { String(validating: content, as: UTF8.self) }
}
