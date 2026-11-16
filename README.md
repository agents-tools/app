# Agents App

A native macOS app for managing Agents configuration. Requires macOS 15 or later.

Select user configuration or add a project directory, then browse declarations, component structure, sources, skill inventory, instruction mappings and diagnostics. The inspector shows authored values and conditions. Adding or removing a project changes only the app’s directory preferences.

Explicit actions can create a new local skill or project instructions through Core, with confirmation and no overwrite. Named prompts use Core rendering and can be previewed and copied. Instruction mappings can be read and copied across selected projects. Typed declaration forms produce local drafts and validate against the captured document; they do not publish configuration. Source discovery, import, applying changes, connection tests, client detection and automatic file monitoring await public Core integration.

Settings includes an opt-out preference and an availability check for on-device assistance on macOS 26 or later. The app makes no model requests.

Open `Agents.xcodeproj` in Xcode 27 and use the `AgentsApp` scheme. The project has app, unit-test and UI-test targets, uses Swift 6 and pins [Agents Core](https://github.com/agents-tools/core) to a full commit revision. Package resolution requires that revision to be available. Local Debug builds use ad hoc signing; release signing and distribution are not configured.

See [application behavior](Documentation/Application.md) for data ownership, action boundaries and operation lifetime.
