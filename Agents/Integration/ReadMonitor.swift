import AgentsCore
import CoreServices
import Foundation

/// One scope's immutable read footprint. Ancestors admit creation and atomic replacement of
/// absent inputs; only matching external paths invalidate reads. Owned writes explicitly refresh. Stream shutdown drains its callback queue.
final class ReadMonitor: @unchecked Sendable {
  private let queue = DispatchQueue(label: "tools.agents.app.read-events")
  private let queueKey = DispatchSpecificKey<UInt8>()
  private var stream: FSEventStreamRef?
  private var dependencies: [ReadDependency] = []
  private let changed: @Sendable () -> Void

  init(changed: @escaping @Sendable () -> Void) {
    self.changed = changed
    queue.setSpecific(key: queueKey, value: 1)
  }
  deinit { stop() }

  func replace(dependencies: [ReadDependency], since: FSEventStreamEventId) throws {
    try queue.sync {
      stopOnQueue()
      self.dependencies = Array(
        Set(
          dependencies.map { dependency in
            switch dependency {
            case .entry(let url): ReadDependency.entry(url.standardizedFileURL)
            case .subtree(let url): ReadDependency.subtree(url.standardizedFileURL)
            }
          }))
      var roots = Set<String>()
      for dependency in self.dependencies {
        let path = dependency.url.path
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
          || !isDirectory.boolValue
        {
          let parent = directory.deletingLastPathComponent()
          if parent == directory { break }
          directory = parent
        }
        roots.insert(directory.path)
      }
      let minimal = roots.filter { path in
        !roots.contains { $0 != path && Self.contains(path, in: $0) }
      }
      guard !minimal.isEmpty else { return }
      var context = FSEventStreamContext(
        version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
        retain: nil, release: nil, copyDescription: nil)
      let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
        guard let info else { return }
        let owner = Unmanaged<ReadMonitor>.fromOpaque(info).takeUnretainedValue()
        let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        for index in 0..<count {
          // History completion is a stream marker, not a file-system change.
          if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
            continue
          }
          let broad =
            flags[index]
            & FSEventStreamEventFlags(
              kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
          if broad
            || ReadMonitor.matches(String(cString: paths[index]), dependencies: owner.dependencies)
          {
            owner.changed()
            break
          }
        }
      }
      guard
        let created = FSEventStreamCreate(
          nil, callback, &context, Array(minimal).sorted() as CFArray, since, 0.2,
          FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
              | kFSEventStreamCreateFlagIgnoreSelf))
      else { throw MonitorFailure() }
      stream = created
      FSEventStreamSetDispatchQueue(created, queue)
      guard FSEventStreamStart(created) else {
        stopOnQueue()
        throw MonitorFailure()
      }
    }
  }

  func stop() {
    // A callback can release the last owner; teardown must also work on its own queue.
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      stopOnQueue()
    } else {
      queue.sync { stopOnQueue() }
    }
  }
  private func stopOnQueue() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
    stream = nil
    dependencies = []
  }
  static func matches(_ event: String, dependencies: [ReadDependency]) -> Bool {
    dependencies.contains { dependency in
      let path = dependency.url.standardizedFileURL.path
      if contains(path, in: event) { return true }
      if case .subtree = dependency { return contains(event, in: path) }
      return false
    }
  }
  private static func contains(_ child: String, in parent: String) -> Bool {
    child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
  }
  private struct MonitorFailure: LocalizedError {
    var errorDescription: String? { "Automatic refresh could not watch these inputs. Use Refresh." }
  }
}
