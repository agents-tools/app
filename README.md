# Agents App

A native macOS app for managing Agents configuration. Requires macOS 15 or later.

Select user configuration or add a project directory, then browse declarations, managed components, sources, resources, deployment status, instruction mappings and diagnostics. The inspector shows authored values and conditions. Adding or removing a project changes only the app’s directory preferences. An unavailable registered project stays listed with its diagnostic.

Configuration editing happens in the app. Typed forms create or edit declarations, including component fields, sources, groups and instructions. Review Core’s proposed changes, then explicitly apply them. Core prepares again and rejects changed inputs before publication. Changes also offers full update, precise component update/removal and locked restore. Source discovery resolves the current authored selection and carries its captured content evidence into review. Errors remain visible with the original scope and operation outcome.

Explicit actions can create a local skill or project instructions through Core, with confirmation and no overwrite. An initialization error has an unconfirmed outcome; inspect the directory before retrying. Named prompts display Core-rendered text for preview and copy. Instruction mappings can be read and copied across selected projects. Import, subscription mutations, connection tests, client detection and automatic file monitoring remain unimplemented.

Runtime inputs requested by a preview are supplied once for that apply and are not stored in preferences. Settings includes an opt-out preference and the system availability check for on-device assistance on macOS 26 or later. The app makes no model requests.

Open `Agents.xcodeproj` in Xcode 27 and use the `AgentsApp` scheme. The project has app, unit-test and UI-test targets, uses Swift 6 and pins [Agents Core](https://github.com/agents-tools/core) to a full commit revision. Package resolution requires that revision to be available. Local Debug builds use ad hoc signing; release signing and distribution are not configured.

See [application behavior](Documentation/Application.md) for data ownership, action boundaries and operation lifetime.
