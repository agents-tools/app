import XCTest

final class AgentsUITests: XCTestCase {
  @MainActor
  func testExistingConfigurationPreviewOpensFromInitialOverviewAndCanBeCancelled() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".agent/evidence/m3/fixtures")
      .appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("home/.agents")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let declaration = directory.appendingPathComponent("agents.json")
    let ledger = directory.appendingPathComponent("agents.resolved")
    let declarationBytes = Data("{\"agents\":[],\"sources\":{}}\n".utf8)
    let ledgerBytes = Data(
      """
      {"version":1,"sources":{},"skills":{},"instructions":{"sections":[],"chatgpt":{},"targets":{}}}
      """.utf8)
    try declarationBytes.write(to: declaration)
    try ledgerBytes.write(to: ledger)

    let app = XCUIApplication()
    app.launchEnvironment["AGENTS_APP_TESTING"] = "1"
    app.launchEnvironment["AGENTS_APP_FIXTURE_ROOT"] = root.path
    app.launch()
    defer { app.terminate() }

    let preview = app.buttons["existingConfiguration.preview"]
    XCTAssertTrue(preview.waitForExistence(timeout: 10))
    XCTAssertEqual(preview.label, "Preview Configuration…")
    preview.click()
    let apply = app.buttons["existingConfiguration.apply"]
    XCTAssertTrue(apply.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    XCTAssertEqual(apply.label, "Apply")
    app.buttons["existingConfiguration.cancel"].click()
    XCTAssertTrue(apply.waitForNonExistence(timeout: 5))
    XCTAssertTrue(preview.isEnabled)
    XCTAssertEqual(try Data(contentsOf: declaration), declarationBytes)
    XCTAssertEqual(try Data(contentsOf: ledger), ledgerBytes)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
      ["agents.json", "agents.resolved"])
  }
}
