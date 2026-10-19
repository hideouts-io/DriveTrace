# DriveTrace build guide

This is the repository build guide for GitHub contributors. DriveTrace is a native Swift Package Manager macOS application with a system SQLite target. The supported source-validation path is separate from local app packaging and from Developer ID distribution.

## Requirements

- macOS 14 or later for local development.
- Swift 6 and a compatible macOS SDK locally.
- The repository-pinned GitHub checks use `macos-26` with Xcode 26.6 and Swift 6.3.3.
- No Google account, OAuth client JSON, token, Drive cache, or private export is required for the source build and synthetic/integration tests.

## Local source checks

Run these commands from the repository root with the app closed:

```sh
./script/test.sh
swift build --product DriveTrace --arch arm64 --scratch-path "$RUNNER_TEMP/drivetrace-build" --jobs 2
xcrun clang -std=c17 -Wall -Wextra -Werror \
  -x c -c Sources/CSQLite/shim.h -o "$TMPDIR/DriveTrace-CSQLite.o"
```

If `RUNNER_TEMP` is not defined in a local shell, use a task-owned scratch directory under `~/Library/Caches`, for example:

```sh
swift build --product DriveTrace --arch arm64 \
  --scratch-path "$HOME/Library/Caches/DriveTrace-development/canonical-build" --jobs 2
```

The repository test script owns the supported Swift Testing invocation. Keep concurrent SwiftPM commands serialized when they share a scratch directory.

## Build and open the native app locally

To package and open the current preview:

```sh
./script/build_and_run.sh
```

This stops the existing task-owned DriveTrace process, builds arm64 and x86_64 Release slices, stages `DriveTrace.app` under `~/Library/Caches/DriveExplorerBuild`, ad-hoc signs and verifies the bundle, creates the local ZIP and opens the app. The generated `dist/DriveTrace.app` is a symlink to the verified cached bundle.

Use the build script as the entry point for local packaging. Do not launch the SwiftUI executable directly; the app needs its bundle identity, resources and native application lifecycle.

The local preview is not a distribution release. It is not Developer ID signed or notarized, and it does not install the app or modify Google Drive. Keep generated bundles, archives, caches, credentials, real Drive data and private reports outside Git.

## GitHub Actions

The workflows are in [`.github/workflows/`](../.github/workflows/) and run automatically for pull requests and pushes to `main`. They can also be started with **Actions → [CI](../actions/workflows/ci.yml) → Run workflow** or **Actions → [CodeQL](../actions/workflows/codeql.yml) → Run workflow** when GitHub offers the manual trigger for the repository.

### CI — Swift build and tests

[`ci.yml`](../.github/workflows/ci.yml) runs on `macos-26` with the explicit Xcode 26.6 developer directory. It:

1. Checks out the repository with a pinned, read-only checkout action.
2. Verifies the selected Xcode and Swift toolchain.
3. Builds the native `DriveTrace` product for arm64.
4. Runs the source and SQLite integration tests.
5. Compiles the `Sources/CSQLite/shim.h` system boundary with strict C warnings.

The required check is named **Swift build and tests**. A passing check validates the source build and configured tests at that revision; it does not prove a live Google account, native visual layout, Developer ID signing, notarization or distribution readiness.

### CodeQL — source analysis

[`codeql.yml`](../.github/workflows/codeql.yml) analyzes three configured languages:

- Swift, with a manual native build and strict extraction-diagnostic rejection.
- C/C++, including the SQLite and Quick Look interoperability boundaries.
- GitHub Actions workflow files.

The workflow retains bounded Swift extraction context on failure and requires successful analysis and SARIF upload for every configured language. A successful setup or an older successful run is not evidence for a different commit; inspect the checks and extraction diagnostics on the current pull-request head.

### Dependabot

[`dependabot.yml`](../.github/dependabot.yml) checks GitHub Actions dependencies weekly and limits the number of open update pull requests. Review action publisher, version and full commit SHA before accepting an update.

## Pull-request checklist

Before requesting review:

1. Run the applicable local checks and inspect the complete diff.
2. Confirm that OAuth files, tokens, real Drive data, private exports, generated bundles and caches are not tracked.
3. Open the pull request’s **Checks** tab and confirm **Swift build and tests** and **CodeQL source analysis** are complete for the current head.
4. Inspect any Swift extraction diagnostics instead of treating source-file counts as complete semantic coverage.
5. Report local, hosted, native UI, real-account, signing and distribution evidence separately.

GitHub Actions do not authorize merging a pull request, creating a release, publishing an artifact, deploying the application, changing repository settings or broadening credentials. Those remain separate project decisions.

## Google sign-in after a local build

Open **DriveTrace → Settings → Connect Google Drive…**. Follow the five-step guide, keep the Desktop OAuth JSON local, and use the default browser only after the intended project and requested scopes are confirmed. The source build and GitHub Actions do not perform Google sign-in or validate live Drive behavior.
