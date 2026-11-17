import AgentsUpdates
import SwiftUI

struct ConnectionDescriptionView: View {
  let description: MCPConnectionDescription
  var body: some View {
    Group {
      LabeledContent("Transport", value: description.transport.rawValue)
      if let executable = description.executable {
        LabeledContent("Executable") { CompactText(text: executable) }
        if description.executableIsCaptured {
          Text("Executable uses captured source content.").foregroundStyle(.secondary)
        }
      }
      if let arguments = description.arguments {
        DetailsGroup("Arguments (in order)") {
          if arguments.isEmpty { Text("No arguments") }
          ForEach(Array(arguments.enumerated()), id: \.offset) { index, argument in
            LabeledContent(String(index + 1)) {
              Text(verbatim: argument.isEmpty ? "Empty argument" : argument)
                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }
          }
        }
      }
      if let directory = description.workingDirectory {
        LabeledContent("Working directory") { CompactText(text: directory) }
        if description.workingDirectoryIsCaptured {
          Text("Working directory uses captured source content.").foregroundStyle(.secondary)
        }
      }
      if let endpoint = description.endpoint {
        LabeledContent("Endpoint") { CompactText(text: endpoint) }
      }
    }
  }
}
