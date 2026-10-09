# DriveTrace repository instructions

- Preserve the native SwiftPM app, system SQLite integration, bundle identity, Keychain service, and existing storage namespaces.
- Keep changes uncommitted until the user authorizes a commit; commit, push, PR creation, merge, release, notarization submission, and deployment each require authorization covering that operation.
- Run the source build and tests in `.github/workflows/ci.yml` for source changes. Keep the `Swift build and tests` check emitted for every PR. Local packaging remains owned by `script/build.sh` and `script/verify_bundle.sh`.
- Keep native CI on Xcode 26.6. Swift CodeQL uses Xcode 16.4/SDK 15.5 with Swift 6 language mode on `macos-15` for the declared macOS 14 contract; verify the actual toolchain and all production sources. Keep Swift and the CSQLite header in the explicit CodeQL builds. Confirm successful analysis for each intended language at the reviewed revision; an enabled setup or successful workflow alone does not establish coverage.
- Keep OAuth client files, tokens, real Drive caches, private exports, and account screenshots outside Git and CI artifacts. Use the existing synthetic tests without connecting a real Google account.
- Report native UI and real-account validation separately from source builds and synthetic tests. Local ad hoc packaging does not establish Developer ID signing, notarization, or distribution readiness.
