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
    try runExternal("/bin/sh", arguments: [
      "-ec",
      """
      path=$1
      /bin/mkdir -p "${path%/*}"
      if [ "$3" = 1 ]; then
        target=$(/usr/bin/mktemp "$path.XXXXXX")
        trap '/bin/rm -f -- "$target"' EXIT
      else
        target=$path
      fi
      printf '%s' "$2" | /usr/bin/base64 -D > "$target"
      if [ "$target" != "$path" ]; then /bin/mv -f -- "$target" "$path"; fi
      """, "fixture-write", url.path, Data(text.utf8).base64EncodedString(), atomic ? "1" : "0",
    ])
  }

  func externalRemove(_ url: URL) throws {
    precondition(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"))
    try runExternal("/bin/rm", arguments: ["-r", "--", url.path])
  }

  private func runExternal(_ executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [
        NSLocalizedDescriptionKey: "\(executable) exited with status \(process.terminationStatus)",
      ])
    }
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
