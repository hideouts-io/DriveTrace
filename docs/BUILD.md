# DriveTrace build guide

This is the repository build guide for GitHub contributors. DriveTrace is a native Swift Package Manager macOS application with a system SQLite target. The supported source-validation path is separate from local app packaging and from Developer ID distribution.

For prerequisites, selecting the preview branch, running tests, packaging, output paths and launching the app, follow the [README build-and-run instructions](../README.md#build-and-run). This guide covers additional contributor checks and GitHub workflows.

## Local source checks

For a source-only build without packaging or launch, run these commands from the repository root. They use a local scratch path and do not require GitHub's `RUNNER_TEMP` environment variable:

```sh
swift build --product DriveTrace \
  --scratch-path "$HOME/Library/Caches/DriveTrace-development" --jobs 2
xcrun clang -std=c17 -Wall -Wextra -Werror \
  -x c -c Sources/CSQLite/shim.h \
  -o "$HOME/Library/Caches/DriveTrace-development/CSQLite.o"
```

The source-only command builds for the host architecture; `script/build.sh` owns universal packaging. Keep concurrent SwiftPM commands serialized when they share a scratch directory. Keep generated bundles, archives, caches, credentials, real Drive data and private reports outside Git.

## GitHub Actions

The workflows are in [`.github/workflows/`](../.github/workflows/) and run automatically for pull requests and pushes to `main`. Use the pull request's **Checks** tab for the current preview. They can also be started with **Actions → [CI](https://github.com/hideouts-io/DriveTrace/actions/workflows/ci.yml) → Run workflow** or **Actions → [CodeQL](https://github.com/hideouts-io/DriveTrace/actions/workflows/codeql.yml) → Run workflow** when GitHub offers the manual trigger for the repository. These workflows validate source; they do not upload a distributable app or publish a release.

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
- C/C++, covering the SQLite header. The Objective-C Quick Look bridge is also compiled with strict warnings, but is not represented in C/C++ CodeQL extraction; compilation is not analysis coverage.
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

For Google sign-in after a local build, follow the [README connection guide](../README.md#connect-your-google-account). Source builds and GitHub Actions do not validate live Drive behavior.
