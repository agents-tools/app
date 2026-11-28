import AgentsUpdates

enum ConnectionLabels {
  static func outcome(_ value: MCPConnectionTestResult.Outcome) -> String {
    switch value {
    case .discovered: "Tools found"
    case .noTools: "Connected; tool discovery unavailable"
    case .incomplete: "Tool discovery incomplete"
    case .failed: "Connection failed"
    }
  }

  static func transport(_ value: MCPConnectionDescription.Transport) -> String {
    switch value {
    case .stdio: "Standard input/output"
    case .streamableHTTP: "Streamable HTTP"
    case .sse: "Server-Sent Events (SSE)"
    }
  }

  static func issue(_ value: MCPConnectionTestResult.Issue) -> String {
    switch value {
    case .invalidInput: "Invalid test input"
    case .bindingUnavailable: "Required runtime input is unavailable"
    case .invalidBinding: "Invalid runtime input"
    case .resourceChanged: "Source content changed; prepare the connection again"
    case .connectionFailed: "Could not connect"
    case .connectionClosed: "Connection closed"
    case .protocolError: "Unexpected protocol response"
    case .unsupportedVersion: "Unsupported protocol version"
    case .authenticationRequired: "Authentication required"
    case .forbidden: "Access denied"
    case .authorityChanged: "Server identity changed"
    case .sessionExpired: "Session expired"
    case .messageLimit: "Message limit reached"
    case .receiveLimit: "Received data exceeds the limit"
    case .sendLimit: "Sent data exceeds the limit"
    case .stderrLimit: "Process error output exceeds the limit"
    case .queueLimit: "Message queue limit reached"
    case .pageLimit: "Tool discovery page limit reached"
    case .toolLimit: "Tool discovery count limit reached"
    case .textLimit: "Response text exceeds the limit"
    case .redirectLimit: "Redirect limit reached"
    case .resumeLimit: "Connection resume limit reached"
    case .cursorCycle: "Server repeated a tool discovery page"
    case .timeout: "Connection test timed out"
    case .cancelled: "Cancelled"
    case .cleanupFailed: "Connection resource cleanup failed"
    }
  }
}
