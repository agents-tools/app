import CoreServices
import Foundation
import Testing

/// Establishes a test boundary only after the host has delivered fixture creation and a sentinel.
final class FixtureEventBoundary: @unchecked Sendable {
  private let lock = NSLock()
  private var observed: [String: (FSEventStreamEventId, FSEventStreamEventFlags)] = [:]
  private var stream: FSEventStreamRef?
  private let queue = DispatchQueue(label: "fixture.creation-boundary")
  init(root: URL) throws {
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, context, count, paths, flags, ids in
      guard let context else { return }
      let owner = Unmanaged<FixtureEventBoundary>.fromOpaque(context).takeUnretainedValue()
      let values = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
      for index in 0..<count {
        let path = String(cString: values[index])
        owner.lock.withLock { owner.observed[path] = (ids[index], flags[index]) }
      }
    }
    let created = try #require(
      FSEventStreamCreate(
        nil, callback, &context, [root.path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)))
    stream = created
    FSEventStreamSetDispatchQueue(created, queue)
    try #require(FSEventStreamStart(created))
  }
  func settle(creation: URL, root: URL) async throws {
    try await wait(for: creation)
    let sentinel = root.appendingPathComponent("creation-observed-\(UUID().uuidString)")
    try Data("boundary".utf8).write(to: sentinel)
    try await wait(for: sentinel)
    let boundary = FSEventsGetCurrentEventId()
    print("SETTLED_FIXTURE_BOUNDARY", boundary)
    try #require(boundary != 0, "Normal host FSEvents is required")
  }
  private func wait(for url: URL) async throws {
    for _ in 0..<500 {
      if let (id, flags) = lock.withLock({ observed[url.path] }),
        flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
      {
        print("OBSERVED_FIXTURE_CREATION", id, String(flags, radix: 16), url.path)
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw BoundaryError.missingEvent(url.path)
  }
  func stop() {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
    stream = nil
    queue.sync {}
  }
  private enum BoundaryError: Error { case missingEvent(String) }
}
