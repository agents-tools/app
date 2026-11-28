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
  private var dependencyIndex = ReadDependencyIndex([])
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
      let supplied = Set(dependencies)
      let index = supplied == self.dependencies ? dependencyIndex : ReadDependencyIndex(supplied)
      var roots = Set<String>()
      for path in index.paths {
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
        var next = ReadDependencyIndex.parent(of: path)
        while let parent = next {
          if roots.contains(parent) { return false }
          next = ReadDependencyIndex.parent(of: parent)
        }
        return true
      }
      if stream != nil, index == dependencyIndex, minimal == self.roots {
        self.dependencies = supplied
        return
      }
      let replayFrom = max(since, lastNotification)
      stopOnQueue()
      guard !minimal.isEmpty else { return }
      self.dependencies = supplied
      dependencyIndex = index
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
            owner.dependencyIndex.matches(String(cString: paths[index]), flags: flags[index])
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
    dependencyIndex = ReadDependencyIndex([])
    roots = []
  }

  private struct MonitorFailure: LocalizedError {
    var errorDescription: String? { "Automatic refresh could not watch these inputs. Use Refresh." }
  }
}

struct ReadDependencyIndex: Equatable {
  private var entries: Set<String> = []
  private var subtrees: Set<String> = []
  private var ancestors: Set<String> = []

  var paths: Set<String> { entries.union(subtrees) }

  init(_ dependencies: some Sequence<ReadDependency>) {
    for dependency in dependencies {
      let path = dependency.url.standardizedFileURL.path
      switch dependency {
      case .entry: entries.insert(path)
      case .subtree: subtrees.insert(path)
      }
      var next = Self.parent(of: path)
      while let parent = next, ancestors.insert(parent).inserted {
        next = Self.parent(of: parent)
      }
    }
  }

  func matches(_ event: String, flags: FSEventStreamEventFlags) -> Bool {
    guard flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0 else {
      return false
    }
    // Directory bookkeeping is not evidence that the entries beneath it changed.
    let structural =
      flags
      & FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
          | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagRootChanged
          | kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagMount
          | kFSEventStreamEventFlagUnmount) != 0
    let directory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
    let metadata =
      flags
      & FSEventStreamEventFlags(
        kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemChangeOwner
          | kFSEventStreamEventFlagItemXattrMod) != 0
    if (structural || metadata) && ancestors.contains(event) { return true }
    if (!directory || structural || metadata) && entries.contains(event) { return true }
    guard !subtrees.isEmpty else { return false }

    // An explicit cache dependency still matches before the walk reaches the working tree.
    let eventWithSeparator = event + "/"
    let cacheBoundary = eventWithSeparator.range(of: "/.git/lfs/objects/").map {
      let path = eventWithSeparator[..<$0.lowerBound]
      return path.isEmpty ? "/" : String(path)
    }
    var next: String? = event
    while let path = next, path != cacheBoundary {
      if subtrees.contains(path) { return true }
      next = Self.parent(of: path)
    }
    return false
  }

  fileprivate static func parent(of path: String) -> String? {
    guard path != "/", let separator = path.lastIndex(of: "/") else { return nil }
    return separator == path.startIndex ? "/" : String(path[..<separator])
  }
}
