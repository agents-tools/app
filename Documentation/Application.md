# Application behavior

Agents App has one main window and a Settings window. Its navigator selects a user or project scope and a configuration page; the inspector shows the current selection. It uses Core’s public manifest, skill and instruction APIs directly.

## Configuration and preferences

Core owns declaration parsing, defaults, resolved state, inventory, mappings and diagnostics. Browsing does not initialize configuration. Missing manifests, invalid manifests, orphan state and unavailable reads remain distinct. Reads are coordinated individually and are not presented as an atomic snapshot across domains. Instruction mappings describe locked state; diagnostics describe the checks Core performed. Richer component declarations remain visible even when a secondary legacy inventory read cannot interpret them.

The app stores only registered project directories, last selected scope, inspector visibility and the assistance preference in its own UserDefaults domain. Adding a directory does not create configuration; removing one does not delete configuration. The app does not use a credential store or start configured client/server executables.

A manual refresh or application activation rereads the scope. Automatic file monitoring is not implemented. Source subscription baselines are displayed as recorded state and are not presented as current update status.

Paths use compact scope-relative presentation where possible. Full paths remain available through help, accessibility and explicit copy actions. The inspector omits synthetic defaulted fields using Core’s source-map evidence, while retaining authored empty collections and explicit native null values. Technical declaration coordinates and document digests are contextual copy actions.

## Explicit content actions

Creating a local skill requires choosing its directory and confirming the requested name and directory. Creating local instructions is available only in a project scope and requires confirmation of that project and requested name. Core owns validation, canonical naming, templates and no-overwrite behavior. The app shows the exact returned location after success; it does not predict a filename using private naming rules. These actions create starter content only. They do not install it, edit the manifest or write resolved state.

Named prompt preview calls Core’s renderer. Locked section order and the current consumer-owned local append are rendered by Core at that call. The app displays returned UTF-8 text and copies it only on explicit action. Instruction mapping export always includes user scope and the selected registered projects, including Core’s missing or unavailable status for each scope. Mapping reads are not an atomic cross-project snapshot.

Declaration forms use public typed manifest values for defaults, sources, components, groups, uses, instruction exports and structural move/remove intents. Component forms cover skills, instructions, MCP servers, hooks, subagents, commands, language servers, permissions, ignores and plugins. Ordered collections preserve order and editable row identity; omitted, empty and explicit-null values remain distinct where the public type supports them. Native decimal text remains exact.

Drafts are held in memory. For an existing declaration, Validate calls Core’s pure document preparation on the captured document and discards the resulting change bytes. Validation does not establish current-disk freshness or publish configuration. Missing-manifest creation, existing-component field replacement and combined preview/apply await the accepted public edit lifecycle. Closing a draft discards it.

## Operation lifetime

The application owns a MainActor observable model independently of views. It registers every read, creation, rendering and validation operation before admitting it to a serial background OperationQueue. Core’s synchronous outer call returns before its completion is delivered to the model. No prepared handle or borrowed source path is retained across actor boundaries.

Cancellation skips queued work while preserving terminal delivery. A running synchronous call completes normally. Changing selection invalidates its presentation; diagnostics are still processed against the original scope before the operation is removed. An actual creation result remains attached to its original request. Declaration selection and structural drafts use Core node identities belonging to the captured document generation.

Normal quit and last-window closure go through an AppKit termination delegate. Quit stops admission, cancels queued work and returns `terminateLater` while any operation remains. The delegate replies only after terminal processing. A reported cleanup failure cancels quit and remains visible in diagnostics. Recovery and cleanup failure resolution require the relevant Core owner; the app does not infer recovery from error text.

## On-device assistance

Settings offers an opt-out preference and displays the system model’s actual availability on macOS 26 or later. Older systems receive the OS requirement. The framework is weak-linked. No session, inference, cloud fallback or model request is implemented. Device acceptance of a future assistance action remains separate from availability presentation.

## Development validation

The shared scheme isolates its test host through explicit Debug-only test inputs and in-memory preferences. A Debug launch may also supply `--agents-fixture-root <absolute-directory>`; that directory contains `home` and `project` subdirectories prepared by the developer. The launch input does not create fixtures. Release builds ignore these inputs.

Unit tests exercise operation ownership and quit decisions with controlled worker and cleanup timing, stale-selection diagnostics, real Core reads, invalid/orphan configuration, no-write browsing, fixture-only creation and overwrite refusal, real prompt rendering and mappings, typed draft validation and source-map presentation. UI acceptance uses the designated computer-use surface; the UI-test target is present without a second automation implementation.
