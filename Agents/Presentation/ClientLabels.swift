import AgentsUpdates

/// Labels describe Core observations without deriving installation or capability decisions.
enum ClientLabels {
  static func observation(_ value: AgentClientObservationStatus) -> String {
    switch value {
    case .present: "Found"
    case .notFound: "Not found"
    case .inaccessible: "Could not access"
    case .invalid: "Invalid"
    case .unavailable: "Unavailable"
    }
  }

  static func role(_ value: AgentClientCommand.Role) -> String {
    switch value {
    case .agentCLI: "Agent command-line tool"
    case .editorLauncher: "Editor launcher"
    }
  }

  static func versionReason(_ value: AgentClientVersionUnknown) -> String {
    switch value {
    case .artifactNotFound: "Installation not found"
    case .unrecognizedLayout: "Version metadata is not recognized for this layout"
    case .missingMetadata: "Version metadata is missing"
    case .unreadableMetadata: "Version metadata could not be read"
    case .malformedMetadata: "Version metadata is invalid"
    case .oversizedMetadata: "Version metadata exceeds the size limit"
    case .nonRegularMetadata: "Version metadata is not a regular file"
    case .missingVersion: "Metadata does not include a version"
    case .unavailable: "Version information is unavailable"
    }
  }

  static func purpose(_ value: AgentClientConfigurationLocation.Purpose) -> String {
    switch value {
    case .skillInstallation: "Skill installation"
    case .skillScan: "Skill search"
    case .instructions: "Instructions"
    case .nativeConfiguration: "Client configuration"
    }
  }

  static func objectRole(_ value: AgentClientConfigurationLocation.ObjectRole) -> String {
    switch value {
    case .file: "File"
    case .container: "Directory"
    }
  }

  static func evidence(_ value: AgentClientSchemaEvidence.Status) -> String {
    switch value {
    case .recorded: "Recorded"
    case .unsupportedUnderEvidence: "Unsupported in recorded evidence"
    case .unverified: "Not verified"
    }
  }

  static func placement(_ value: AgentClientSchemaEvidence.Placement) -> String {
    switch value {
    case .standalone: "Standalone"
    case .pluginMember: "Plugin member"
    }
  }

  static func scope(_ value: String) -> String {
    switch value {
    case "user": "User"
    case "project": "Project"
    case "local": "Local"
    default: value
    }
  }
}
