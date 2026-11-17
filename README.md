# Agents App

A native macOS app for managing Agents configuration. Requires macOS 15 or later.

Select user configuration or add a project directory, then browse declarations, managed components, sources, resources, deployment status, instruction mappings and diagnostics. The inspector shows authored values and conditions. Adding or removing a project changes only the app’s directory preferences. An unavailable registered project stays listed with its diagnostic.

Configuration editing happens in the app. Typed forms create or edit declarations, including component fields, sources, groups and instructions. Review Core’s proposed changes, then explicitly apply them. Core prepares again and rejects changed inputs before publication. Changes also offers full update, precise component update/removal and locked restore. Source discovery resolves the current authored selection and carries its captured content evidence into review. Errors remain visible with the original scope and operation outcome.

Explicit actions create a local skill or project instructions from a Core-owned file/template preview, with confirmation, no overwrite and typed completion/recovery outcomes. Named prompts display Core-rendered text for preview and copy. Instruction mappings can be read and copied across selected projects. Sources offers subscription add/remove review and captured import inspection followed by the same configuration review/apply flow. Imports preserve Core's metadata, integrity and independent-authoring constraints. Explicit selection keys, source coordinates and independent skill paths can be supplied before inspecting again; unresolved conversions remain visible. Subscription checks display recorded/current baselines and file differences without deploying or marking them read. Managed MCP components offer an explicit connection-test action with one-time inputs and cancellation. Complete command/endpoint review and client inspection still require public Core metadata and native acceptance.

Native file events monitor Core's durable read footprints, including previously absent inputs. External edits retain dirty drafts and invalidate previews. The stream excludes this process's own filesystem changes; owned writes explicitly refresh after their actual outer terminal. Retained edits can be reviewed again only against the identical Core document digest; a changed declaration requires a new draft.

Runtime inputs requested by a preview are supplied once for that apply and are not stored in preferences. Optional on-device assistance on macOS 26 or later explains a selected managed skill, translates its description, summarizes an update or explains configuration changes. Actions appear only when enabled and the system model is available. Review the minimal input before generating auxiliary text; generated text never changes configuration. There is no cloud fallback.

Open `Agents.xcodeproj` in Xcode 27 and use the `AgentsApp` scheme. The project has app, unit-test and UI-test targets, uses Swift 6 and pins [Agents Core](https://github.com/agents-tools/core) to a full commit revision. Package resolution requires that revision to be available. Local Debug builds use ad hoc signing; release signing and distribution are not configured.

See [application behavior](Documentation/Application.md) for data ownership, action boundaries and operation lifetime.
