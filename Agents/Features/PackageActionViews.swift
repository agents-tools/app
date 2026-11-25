import AgentsCore
import AgentsUpdates
import SwiftUI

extension LifecycleEvent {
  var actionTitle: String {
    switch self {
    case .preInstall: "Before Install"
    case .postInstall: "After Install"
    case .preUpdate: "Before Update"
    case .postUpdate: "After Update"
    case .preUninstall: "Before Removal"
    case .postUninstall: "After Removal"
    case .preCompile: "Before Compiling"
    }
  }
}

extension LifecycleAuthority {
  var actionTitle: String {
    switch self {
    case .administrator: "Administrator"
    case .user: "User"
    case .project: "Project"
    }
  }
}

extension LifecycleWithholding {
  var actionMessage: String {
    switch self {
    case .administratorSourceInvalid: "An administrator configuration is invalid or unavailable."
    case .sourceChanged: "The configuration changed after review."
    case .projectChanged: "The project folder changed after review."
    case .receiptUnavailable: "Saved project access is unavailable."
    case .projectUntrusted: "Enable this project’s current configuration first."
    case .trustChanged: "Project access changed after review."
    case .disabled: "Package actions are disabled for this process."
    case .policyDenied: "Organization policy blocks package actions."
    case .policyUnavailable: "Organization policy could not be verified."
    case .packageAdmission: "The package operation did not pass its checks."
    case .recoveryPending: "Configuration recovery needs attention."
    case .packageDidNotComplete: "The package operation did not finish successfully."
    case .cancelled: "The operation was cancelled."
    case .headerExpansionRefused:
      "A request header could not be supplied under this action’s rules."
    }
  }
}

extension LifecycleActionSummary {
  struct Selection: Hashable {
    let source: URL
    let event: LifecycleEvent
    let index: Int
  }

  var selection: Selection { .init(source: source.file, event: event, index: index) }
  var actionTitle: String { kind == .command ? "Shell Command" : "HTTPS Request" }
}

struct PackageActionRow: View {
  let action: LifecycleActionSummary
  var runnableLabel: LocalizedStringKey = "May Run"

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline) {
        Text(action.actionTitle)
        Text(verbatim: action.target)
          .font(.callout.monospaced())
          .lineLimit(1).truncationMode(.middle)
        Spacer()
        Label(
          action.withheld == nil ? runnableLabel : "Withheld",
          systemImage: action.withheld == nil ? "play.circle" : "nosign"
        ).font(.caption)
      }
      Text("\(action.event.actionTitle) · \(sourceTitle) · Action \(action.index + 1)")
        .font(.caption).foregroundStyle(.secondary)
      if let reason = action.withheld {
        Text(reason.actionMessage).font(.caption).foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
    .help(action.source.file.path)
  }

  private var sourceTitle: String {
    let authority = action.source.authority
    return authority == .administrator
      ? authority.actionTitle + " · " + action.source.file.lastPathComponent
      : authority.actionTitle
  }
}

struct PackageActionFinding: View {
  let finding: LifecycleDiagnostic

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(finding.message, systemImage: "exclamationmark.triangle")
      Text(
        [
          finding.source.authority.actionTitle,
          finding.event.map { LifecycleEvent(rawValue: $0)?.actionTitle ?? $0 },
          finding.index.map { "Action \($0 + 1)" },
          finding.field?.isEmpty == false ? finding.field : nil,
        ].compactMap { $0 }.joined(separator: " · ")
      )
      .font(.caption).foregroundStyle(.secondary)
      PathView(url: finding.source.file)
    }
    .accessibilityElement(children: .combine)
  }
}

struct PackageActionPreview: View {
  let inspection: LifecycleInspection
  @State private var expanded: Bool

  init(inspection: LifecycleInspection) {
    self.inspection = inspection
    _expanded = State(
      initialValue: inspection.actions.count <= 3
        || inspection.actions.contains { $0.source.authority == .project && $0.withheld == nil }
        || !inspection.diagnostics.isEmpty || inspection.allStartsWithheld != nil)
  }

  var body: some View {
    if !inspection.actions.isEmpty || !inspection.diagnostics.isEmpty {
      Section {
        DisclosureGroup(isExpanded: $expanded) {
          if let reason = inspection.allStartsWithheld {
            Text(reason.actionMessage).foregroundStyle(.secondary)
          }
          ForEach(LifecycleEvent.allCases, id: \.self) { event in
            ForEach(inspection.actions.filter { $0.event == event }, id: \.selection) { action in
              PackageActionRow(action: action)
            }
          }
          ForEach(Array(inspection.diagnostics.enumerated()), id: \.offset) { _, finding in
            PackageActionFinding(finding: finding)
          }
        } label: {
          let runnable = inspection.actions.filter { $0.withheld == nil }.count
          let withheld = inspection.actions.count - runnable
          LabeledContent("Package Actions", value: "\(runnable) may run · \(withheld) withheld")
        }
      }
    }
  }
}

struct PackageActionResults: View {
  let results: [LifecycleActionResult]

  var body: some View {
    if !results.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text("Package Action Results").font(.headline)
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(results, id: \.action.selection) { result in
              resultRow(result)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 180)
      }
    }
  }

  private func resultRow(_ result: LifecycleActionResult) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(result.action.event.actionTitle + " · " + result.action.actionTitle)
        .font(.callout.weight(.medium))
      Text(verbatim: result.action.source.authority.actionTitle + " · " + result.action.target)
        .font(.caption)
      Label(result.actionStatus, systemImage: result.actionStatusSymbol)
      if result.stdoutBytes > 0 || result.stderrBytes > 0 {
        Text("Output \(result.stdoutBytes) bytes · Errors \(result.stderrBytes) bytes")
          .font(.caption)
      }
      if result.processGroupCleanedUp == false {
        Text("The command’s processes could not all be stopped.").font(.caption)
      }
      ForEach(Array(result.diagnostics.enumerated()), id: \.offset) { _, finding in
        PackageActionFinding(finding: finding)
      }
    }.accessibilityElement(children: .combine)
  }
}

extension LifecycleActionResult {
  fileprivate var actionStatus: String {
    switch disposition {
    case .withheld: withholding?.actionMessage ?? "Action withheld."
    case .commandSucceeded: "Command finished."
    case .commandFailed:
      if let exitStatus {
        "Command exited with status \(exitStatus)."
      } else if let signal {
        "Command stopped with signal \(signal)."
      } else {
        "Command failed."
      }
    case .commandTimedOut: "Command timed out."
    case .commandOutputLimit: "Command exceeded its output limit."
    case .commandCancelled: "Command was cancelled."
    case .commandLaunchFailed: "Command could not start."
    case .httpSucceeded:
      httpStatus.map { "Request succeeded (HTTP \($0))." } ?? "Request succeeded."
    case .httpRejected:
      httpStatus.map { "Request was rejected (HTTP \($0))." } ?? "Request was rejected."
    case .deliveryUnknown: "Request delivery could not be confirmed."
    }
  }

  fileprivate var actionStatusSymbol: String {
    switch disposition {
    case .commandSucceeded, .httpSucceeded: "checkmark.circle"
    case .withheld: "nosign"
    default: "exclamationmark.circle"
    }
  }
}
