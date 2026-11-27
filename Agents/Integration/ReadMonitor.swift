import AgentsCore
import CoreServices
import Foundation

/// One scope's immutable read footprint. Ancestors admit creation and atomic replacement of
/// absent inputs. Owned writes explicitly refresh. Stream shutdown drains its callback queue.
final class ReadMonitor: @unchecked Sendable {
  private let queue = DispatchQueue(label: "tools.agents.app.read-events")
  private let queueKey = DispatchSpecificKey<UInt8>()
  private var stream: FSEventStreamRef?
  private var dependencies: Set<ReadDependency> = []
  private var roots: Set<String> = []
  private var lastNotification: FSEventStreamEventId = 0
  private let changed: @Sendable () -> Void

  init(changed: @escaping @Sendable () -> Void) {
    self.changed = changed
    queue.setSpecific(key: queueKey, value: 1)
  }
  deinit { stop() }

  func replace(dependencies: [ReadDependency], since: FSEventStreamEventId) throws {
    try queue.sync {
      let normalized = Set(
        dependencies.map { dependency in
          switch dependency {
          case .entry(let url): ReadDependency.entry(url.standardizedFileURL)
          case .subtree(let url): ReadDependency.subtree(url.standardizedFileURL)
          }
        })
      var roots = Set<String>()
      for dependency in normalized {
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
      if stream != nil, normalized == self.dependencies, minimal == self.roots { return }
      let replayFrom = max(since, lastNotification)
      stopOnQueue()
      guard !minimal.isEmpty else { return }
      self.dependencies = normalized
      self.roots = minimal
      var context = FSEventStreamContext(
        version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
        retain: nil, release: nil, copyDescription: nil)
      let callback: FSEventStreamCallback = { _, info, count, rawPaths, flags, ids in
        guard let info else { return }
        let owner = Unmanaged<ReadMonitor>.fromOpaque(info).takeUnretainedValue()
        let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        var changed = false
        for index in 0..<count where ids[index] == 0 || ids[index] > owner.lastNotification {
          guard
            ReadMonitor.matches(
              String(cString: paths[index]), flags: flags[index], dependencies: owner.dependencies)
          else { continue }
          if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            owner.roots.removeAll()
          }
          owner.lastNotification = max(owner.lastNotification, ids[index])
          changed = true
        }
        if changed { owner.changed() }
      }
      guard
        let created = FSEventStreamCreate(
          nil, callback, &context, Array(minimal).sorted() as CFArray, replayFrom, 0.2,
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
    roots = []
  }

  static func matches(
    _ event: String, flags: FSEventStreamEventFlags, dependencies: some Sequence<ReadDependency>
  ) -> Bool {
    guard flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0 else {
      return false
    }
    // Directory bookkeeping is not evidence that the entries beneath it changed.
    let structural =
      flags
      & FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
          | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagRootChanged
          | kFSEventStreamEventFlagMustScanSubDirs) != 0
    let directory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
    let metadata =
      flags
      & FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemChangeOwner
          | kFSEventStreamEventFlagItemXattrMod) != 0
    let eventWithSeparator = event + "/"
    let cacheRoot = eventWithSeparator.range(of: "/.git/lfs/objects/").map {
      let root = String(eventWithSeparator[..<$0.lowerBound])
      return root.isEmpty ? "/" : root
    }
    return dependencies.contains { dependency in
      let path = dependency.url.standardizedFileURL.path
      if event != path && (structural || metadata) && contains(path, in: event) { return true }
      switch dependency {
      case .entry:
        return event == path && (!directory || structural || metadata)
      case .subtree:
        // Working-tree interests exclude incidental Git LFS object hydration.
        // A dependency that explicitly addresses the cache still receives its events.
        if let cacheRoot, contains(cacheRoot, in: path) { return false }
        return contains(event, in: path)
      }
    }
  }
  private static func contains(_ child: String, in parent: String) -> Bool {
    child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
  }
  private struct MonitorFailure: LocalizedError {
    var errorDescription: String? { "Automatic refresh could not watch these inputs. Use Refresh." }
  }
}
