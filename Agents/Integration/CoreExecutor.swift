import AgentsCore
import Foundation

/// Cancellation of queued work never skips its terminal delivery. Running synchronous Core work
/// remains owned until its entire outer call, including recovery and cleanup, has returned.
final class OperationAdmission: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var task: Task<Void, Never>?

  func cancel() {
    let ownedTask = lock.withLock {
      cancelled = true
      return task
    }
    ownedTask?.cancel()
  }

  func begin() -> Bool {
    lock.withLock { !cancelled }
  }

  func startTask(_ work: @escaping @Sendable () async -> Void) -> Bool {
    lock.withLock {
      guard !cancelled else { return false }
      task = Task.detached(priority: .userInitiated) { [self] in
        await work()
        lock.withLock { task = nil }
      }
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
  let updateTerminal: UpdateTerminal?
  let readDependencies: [ReadDependency]

  init(
    disposition: Disposition, snapshot: WorkspaceSnapshot? = nil,
    diagnostics: [AppDiagnostic] = [], output: ContentOutput? = nil,
    updateTerminal: UpdateTerminal? = nil, readDependencies: [ReadDependency] = []
  ) {
    self.disposition = disposition
    self.snapshot = snapshot
    self.diagnostics = diagnostics
    self.output = output
    self.updateTerminal = updateTerminal
    self.readDependencies = readDependencies
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

  func submitAsync(
    admission: OperationAdmission, work: @escaping @Sendable () async -> CoreCompletion,
    terminal: @escaping @Sendable (CoreCompletion) -> Void
  ) {
    queue.addOperation { [queue] in
      // Keep this operation's place on the serial worker while Core awaits its actions.
      queue.isSuspended = true
      let started = admission.startTask {
        terminal(admission.begin() ? await work() : .cancelled)
        queue.isSuspended = false
      }
      if !started {
        terminal(.cancelled)
        queue.isSuspended = false
      }
    }
  }
}
