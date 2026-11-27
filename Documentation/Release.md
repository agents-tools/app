# Releasing Agents App

GitHub Releases distributes a universal ZIP for Apple silicon and Intel Macs running macOS 15 or later. The release links a SHA-256 checksum alongside the ZIP. Run `shasum -a 256 -c Agents-App-0.1.0-universal.zip.sha256` from the directory containing both files to verify the first release.

## Repository setup

- Enable [release immutability](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes) for this repository.
- Configure the GitHub Actions `production` environment for deployment from `main` only, with required reviewers and self-review disabled. Confirm immutability is enabled before approving the deployment.
- Set environment variables `APPLE_TEAM_ID` and `DEVELOPER_ID_SIGNING_IDENTITY` to the team and complete Developer ID Application identity.
- Set environment secrets `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD` for that certificate and its private key. Set `ASC_API_KEY_P8_BASE64`, `ASC_API_KEY_ID`, and `ASC_API_ISSUER_ID` for a Team App Store Connect API key allowed to notarize the app. The application uses hardened runtime and requires no provisioning profile for this distribution.
- The [GitHub-hosted Xcode 27 image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) supplies the compiler and macOS SDK. Use its selected Xcode version to resolve [Agents Core](https://github.com/agents-tools/core) when updating the dependency. Commit the Xcode workspace's `Package.resolved` alongside the project pin. The pinned Core commit must be available in the public repository before the release build.

## Publish

1. Confirm the accepted release commit is the tip of `main`, with its checks passed. Check the app target's Release `MARKETING_VERSION` in `Agents.xcodeproj`. For the first release it is `0.1.0`.
2. After the owner approves the tag, create and push the annotated `v0.1.0` tag at the exact accepted commit. Keep published tags fixed.
3. Dispatch the **Release** workflow on `main` with the tag and full accepted commit SHA. The workflow verifies the dispatch commit and remote tag before the protected job, then verifies them again before signing and publication.
4. The production job archives both architectures using the committed package lock. It signs with Developer ID and a secure timestamp, notarizes with the Team API key, and staples and verifies the app extracted from the final ZIP. The job publishes the draft only after uploading both assets, then verifies release immutability and the unauthenticated public downloads.

If the run fails during publication, inspect the release and the workflow log before retrying. A failed draft can retain uploaded assets. Resolve that draft with the release owner before starting a fresh candidate. Published tags and assets are fixed.
