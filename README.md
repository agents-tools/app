# Agents App

A native macOS app for inspecting Agents configuration. Requires macOS 15 or later.

Select user configuration or add a project directory, then browse declarations, component structure, sources, skill inventory, instruction mappings and diagnostics. The inspector shows authored values and conditions. Refresh rereads configuration; adding or removing a project only changes the app’s directory preferences.

The current implementation is read-only. Configuration editing, source discovery, import, applying changes, connection tests, client detection and on-device assistance are unavailable. Their explanations do not perform those operations.

Open `Agents.xcodeproj` in Xcode 27 and use the `AgentsApp` scheme. The project has app, unit-test and UI-test targets, uses Swift 6 and pins [Agents Core](https://github.com/agents-tools/core) to a full commit revision. Package resolution requires that revision to be available. Local Debug builds use ad hoc signing; release signing and distribution are not configured.

See [application behavior](Documentation/Application.md) for data ownership and operation lifetime.
