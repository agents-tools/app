import AgentsUpdates
import SwiftUI

struct ClientSettingsView: View {
  @Bindable var model: AppModel
  var body: some View {
    Form {
      Section("Agent Clients") {
        HStack {
          Button(model.clientSettings.inspection == nil ? "Detect Clients" : "Detect Again") {
            model.redetectClients()
          }.disabled(model.isTerminating)
          if model.clientSettings.busy {
            ProgressView().controlSize(.small)
            Button("Cancel Queued Detection") { model.cancelClientDetection() }
          }
        }
        Text(
          "Passive inspection reads installation metadata and configuration locations. It does not start clients. Detect again to refresh these observations."
        )
        .foregroundStyle(.secondary)
        if let message = model.clientSettings.message { Text(message) }
        if let report = model.clientSettings.inspection {
          LabeledContent("Observed from") { Text(report.startedAt, style: .time) }
          LabeledContent("Observed through") { Text(report.finishedAt, style: .time) }
          LabeledContent("Configuration scope", value: report.scope.rawValue)
          LabeledContent("Home") { PathView(url: report.homeDirectory) }
          DetailsGroup("PATH Coverage") {
            Text(
              report.pathCoverage.pathWasSupplied ? "PATH was supplied." : "PATH was not supplied.")
            ForEach(Array(report.pathCoverage.absoluteDirectories.enumerated()), id: \.offset) {
              _, url in
              PathView(url: url)
            }
            ForEach(Array(report.pathCoverage.excludedEntries.enumerated()), id: \.offset) {
              _, entry in
              LabeledContent("Excluded entry", value: entry.isEmpty ? "Empty entry" : entry)
            }
            Text(
              "Only absolute PATH entries are searched. Shell aliases, functions and other installations are outside this coverage."
            )
            .foregroundStyle(.secondary)
          }
          ForEach(report.clients, id: \.agent) { client in
            ClientRecordView(client: client)
          }
        } else if !model.clientSettings.busy {
          Text("No client inspection yet.").foregroundStyle(.secondary)
        }
      }
    }.formStyle(.grouped)
  }
}

private struct ClientRecordView: View {
  let client: AgentClientRecord
  var body: some View {
    DetailsGroup(client.agent.displayName) {
      ForEach(Array(client.commands.enumerated()), id: \.offset) { _, command in
        DetailsGroup(command.name + " · " + command.role.rawValue) {
          LabeledContent("Observation", value: command.status.rawValue)
          if let url = command.location {
            LabeledContent("Selected executable") { PathView(url: url) }
          }
          if let url = command.resolvedLocation {
            LabeledContent("Resolved executable") { PathView(url: url) }
          }
          ClientVersionView(version: command.version)
          ForEach(Array(command.lookupIssues.enumerated()), id: \.offset) { _, issue in
            LabeledContent(issue.status.rawValue) {
              CompactText(text: issue.path + " · " + issue.reason)
            }
          }
          if !command.lookupIssues.isEmpty {
            Text("Earlier lookup errors mean this selection may differ from shell resolution.")
              .foregroundStyle(.secondary)
          }
        }
      }
      ForEach(Array(client.applications.enumerated()), id: \.offset) { _, application in
        DetailsGroup("Application") {
          LabeledContent("Observation", value: application.status.rawValue)
          if let identifier = application.bundleIdentifier {
            LabeledContent("Bundle identifier", value: identifier)
          }
          if let url = application.location { PathView(url: url) }
          ClientVersionView(version: application.version)
        }
      }
      DetailsGroup("Configuration Locations") {
        ForEach(Array(client.configurationLocations.enumerated()), id: \.offset) { _, location in
          DetailsGroup(location.identity) {
            LabeledContent("Scope", value: location.scope)
            LabeledContent("Purpose", value: location.purpose.rawValue)
            LabeledContent("Object", value: location.objectRole.rawValue)
            LabeledContent("Observation", value: location.status.rawValue)
            if let url = location.location { PathView(url: url) }
            if let diagnostic = location.diagnostic { Text(diagnostic) }
          }
        }
      }
      DetailsGroup("Schema Evidence") {
        Text(
          "Recorded revisions describe frozen schema evidence, not detected client versions. Configuration review determines whether a change can be applied."
        )
        .foregroundStyle(.secondary)
        ForEach(Array(client.schemaEvidence.enumerated()), id: \.offset) { _, evidence in
          DetailsGroup(
            evidence.surface.displayName + " · " + DeclarationLabels.kind(evidence.kind.rawValue)
          ) {
            LabeledContent("Surface", value: evidence.surface.identifier)
            LabeledContent("Scope", value: evidence.scope)
            LabeledContent("Placement", value: evidence.placement.rawValue)
            LabeledContent("Evidence", value: evidence.status.rawValue)
            if let revision = evidence.revision {
              LabeledContent("Evidence revision") { CompactText(text: revision) }
            }
            ForEach(Array(evidence.sources.enumerated()), id: \.offset) { _, source in
              CompactText(text: source)
            }
            if let limitation = evidence.limitation { Text(limitation) }
          }
        }
      }
    }
  }
}

private struct ClientVersionView: View {
  let version: AgentClientVersion
  var body: some View {
    LabeledContent("Version", value: version.rawVersion ?? "Unknown")
    if let reason = version.unknownReason {
      LabeledContent("Unknown reason", value: reason.rawValue)
    }
    if let build = version.build { LabeledContent("Build", value: build) }
    if let url = version.metadataURL { LabeledContent("Metadata") { PathView(url: url) } }
    if let key = version.metadataKey { LabeledContent("Metadata key", value: key) }
  }
}
