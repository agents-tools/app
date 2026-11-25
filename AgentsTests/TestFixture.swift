import Foundation

struct TestFixture: Sendable {
  let root: URL
  var home: URL { root.appendingPathComponent("home") }
  var project: URL { root.appendingPathComponent("project") }
  var environment: [String: String] {
    ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
  }

  init() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let output =
      ProcessInfo.processInfo.environment["AGENTS_TEST_OUTPUT_ROOT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
      } ?? repository.appendingPathComponent(".agent/evidence/m3/fixtures")
    root = output.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  }

  @discardableResult
  func writeManifest(_ text: String, user: Bool = false) throws -> URL {
    let directory =
      user ? home.appendingPathComponent(".agents") : project.appendingPathComponent(".agent")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest = directory.appendingPathComponent("agents.yaml")
    try Data(text.utf8).write(to: manifest)
    return manifest
  }

  func externalWrite(_ text: String, to url: URL, atomic: Bool = false) throws {
    precondition(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-c",
      """
      import base64, os, pathlib, sys, uuid
      path = pathlib.Path(sys.argv[1])
      path.parent.mkdir(parents=True, exist_ok=True)
      target = path.with_name(path.name + '.' + str(uuid.uuid4())) if sys.argv[3] == '1' else path
      target.write_bytes(base64.b64decode(sys.argv[2]))
      if target != path: os.replace(target, path)
      """, url.path, Data(text.utf8).base64EncodedString(), atomic ? "1" : "0",
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
  }

  func externalRemove(_ url: URL) throws {
    precondition(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", "import shutil,sys; shutil.rmtree(sys.argv[1])", url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
  }

  func remove() throws { try FileManager.default.removeItem(at: root) }

  func entries() throws -> [String: Data] {
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey])!
    var files: [String: Data] = [:]
    for case let file as URL in enumerator {
      if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        files[String(file.path.dropFirst(root.path.count))] = try Data(contentsOf: file)
      }
    }
    return files
  }
}
