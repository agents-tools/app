import Foundation

/// Cancellation of queued work never skips its terminal delivery. Running synchronous Core work
/// remains owned until its entire outer call, including recovery and cleanup, has returned.
final class OperationAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.withLock { cancelled = true }
  }

  func begin() -> Bool {
    lock.withLock {
      guard !cancelled else { return false }
      return true
    }
  }
}

struct CoreCompletion: Sendable {
  enum Disposition: Sendable { case completed, cancelled, failed }
  let disposition: Disposition
  let snapshot: WorkspaceSnapshot?
  let diagnostics: [AppDiagnostic]
  let output: ContentOutput?

  init(
    disposition: Disposition, snapshot: WorkspaceSnapshot? = nil,
    diagnostics: [AppDiagnostic] = [], output: ContentOutput? = nil
  ) {
    self.disposition = disposition
    self.snapshot = snapshot
    self.diagnostics = diagnostics
    self.output = output
  }

  static var cancelled: Self { Self(disposition: .cancelled, snapshot: nil, diagnostics: []) }
}

final class CoreExecutor: Sendable {
  private let queue: OperationQueue

  init() {
    queue = OperationQueue()
    queue.name = "tools.agents.app.core"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
  }

  func submit(
    admission: OperationAdmission, work: @escaping @Sendable () -> CoreCompletion,
    terminal: @escaping @Sendable (CoreCompletion) -> Void
  ) {
    queue.addOperation {
      let result = admission.begin() ? work() : .cancelled
      terminal(result)
    }
  }
}
