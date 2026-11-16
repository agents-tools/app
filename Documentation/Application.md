# Application behavior

Agents App has one main window and a Settings window. Its navigator selects a user or project scope and a configuration page; the inspector shows the current selection. It uses Core’s public manifest, skill and instruction APIs directly.

## Configuration and preferences

Core owns declaration parsing, defaults, resolved state, inventory, mappings and diagnostics. The app does not initialize configuration while browsing. Missing manifests, invalid manifests, orphan state and unavailable reads remain distinct. Reads are coordinated individually and are not presented as an atomic snapshot across domains. Instruction mappings describe locked state; diagnostics describe the checks Core performed.

The app stores only registered project directories, last selected scope, inspector visibility and the assistance preference in its own UserDefaults domain. Adding a directory does not create configuration; removing one does not delete configuration. The current app does not use a credential store or start configured client/server executables.

A manual refresh or application activation rereads the scope. Automatic file monitoring is not implemented. Source subscription baselines are displayed as recorded state and are not presented as current update status.

## Operation lifetime

The application owns a MainActor observable model independently of views. It registers each operation before admitting it to a serial background OperationQueue. Core’s synchronous outer call returns before its completion is delivered to the model. No prepared handle or borrowed source path is retained across actor boundaries.

Cancellation skips queued work while preserving terminal delivery. A running synchronous read completes normally. Changing selection invalidates its content; its diagnostics are still processed against the original scope before the operation is removed. Declaration selection uses Core node identities belonging to the exact document generation.

Normal quit and last-window closure go through an AppKit termination delegate. Quit stops admission, cancels queued work and returns `terminateLater` while any operation remains. The delegate replies only after terminal processing. A reported cleanup failure cancels quit and remains visible in diagnostics. Recovery and cleanup failure resolution require the relevant Core owner; the app does not infer recovery from error text.

## Development validation

The shared scheme isolates its test host through explicit Debug-only test inputs and in-memory preferences. A Debug launch may also supply `--agents-fixture-root <absolute-directory>`; that directory contains `home` and `project` subdirectories prepared by the developer. The launch input does not create fixtures. Release builds ignore these inputs.

The unit tests exercise operation ownership and quit decisions with controlled worker and cleanup timing, stale-selection diagnostics, real Core reads, invalid/orphan configuration, no-write browsing and package-schema access. UI acceptance uses the designated computer-use surface; the UI-test target is present without a second automation implementation.
