# Releasing Agents App

GitHub Releases distributes a universal ZIP for Apple silicon and Intel Macs running macOS 15 or later. The release links a SHA-256 checksum alongside the ZIP. Run `shasum -a 256 -c Agents-App-0.1.0-universal.zip.sha256` from the directory containing both files to verify the first release.

## Repository setup

- Restrict the GitHub Actions `production` environment to deployments from `master`.
- Set environment variables `APPLE_TEAM_ID` and `DEVELOPER_ID_SIGNING_IDENTITY` to the team and complete Developer ID Application identity.
- Set environment secrets `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD` for that certificate and its private key. Set `ASC_API_KEY_P8_BASE64`, `ASC_API_KEY_ID`, and `ASC_API_ISSUER_ID` for a Team App Store Connect API key allowed to notarize the app. The application uses hardened runtime and requires no provisioning profile for this distribution.
- The [GitHub-hosted Xcode 27 image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) supplies the compiler and macOS SDK. Use its selected Xcode version to resolve [Agents Core](https://github.com/agents-tools/core) when updating the dependency. Commit the Xcode workspace's `Package.resolved` alongside the project pin. The pinned Core commit must be available in the public repository before the app check or release build.

## Publish

1. Confirm the accepted release commit is the tip of `master` and its **Check** workflow passed on the master-branch push. Check the app target's Release `MARKETING_VERSION` in `Agents.xcodeproj`. For the first release it is `0.1.0`.
2. After the owner approves the tag, create and push the annotated `v0.1.0` tag at the exact accepted commit. Keep published tags fixed.
3. Dispatch the **Release** workflow on `master` with the `publish` operation, tag, and full accepted commit SHA. The workflow verifies the remote tag and exact master check before the protected job.
4. The production job archives both architectures using the committed package lock. It signs with Developer ID and a secure timestamp, notarizes with the Team API key, and staples and verifies the app extracted from the final ZIP. The job preserves the signed ZIP, checksum, and tag identity as a workflow artifact before creating or completing a draft release. It then verifies the unauthenticated public downloads against that candidate.

Record the original signing run ID with the release. To complete an interrupted publication, dispatch `publish` with that ID as `candidate_run_id` while the approved commit is still the tip of `master`. Existing assets must match the preserved candidate. For a published release, dispatch `verify-public` with the original signing run ID, tag and full release commit to verify the downloads while the artifact is retained. This operation uses read-only GitHub permissions. Published tags and assets stay fixed.
