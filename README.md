# Drive Explorer for macOS

### Native Google Drive exploration, advanced search, storage insights, and activity evidence

<p align="center">
  <img src="Sources/DriveExplorer/Resources/drive-explorer-logo.png" width="280" alt="Drive Explorer red, black, and silver cloud-search logo">
</p>

<p align="center">
  Find what is new, what is large, where it lives, and what the available evidence says about who changed it.
</p>

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-000000?logo=apple&logoColor=white)
![Language](https://img.shields.io/badge/language-Swift%206-F05138?logo=swift&logoColor=white)
![Interface](https://img.shields.io/badge/interface-native%20SwiftUI-0969da)
![Access](https://img.shields.io/badge/Google%20Drive-read--only-1a7f37)
![Status](https://img.shields.io/badge/status-work%20in%20progress-orange)
[![License](https://img.shields.io/badge/license-MIT-2da44e)](LICENSE)

> [!IMPORTANT]
> **Work in progress — not done yet.** This repository contains a runnable native preview, not a production release. Local storage, search, exports, and synthetic API scenarios have automated coverage; native screens have been exercised with demo data. **Real Google account sign-in, synchronization, token refresh, and notification delivery have not yet been validated end to end.** See [current status](#current-status) and [planned work — not done yet](#planned-work--not-done-yet).

---

## Contents

- [Overview](#overview)
- [Current status](#current-status)
- [Native app screenshots](#native-app-screenshots)
- [What it does](#what-it-does)
- [Build and run](#build-and-run)
- [Connect your Google account](#connect-your-google-account)
- [Using the explorer](#using-the-explorer)
- [Understanding the evidence](#understanding-the-evidence)
- [Data and architecture](#data-and-architecture)
- [Privacy and local data](#privacy-and-local-data)
- [Planned work — not done yet](#planned-work--not-done-yet)
- [Testing and verification](#testing-and-verification)
- [Troubleshooting](#troubleshooting)
- [Repository structure](#repository-structure)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

Drive Explorer is a native SwiftUI desktop application for browsing and investigating Google Drive metadata. It combines the **Google Drive API** for files, folders, permissions, and change tracking with the **Google Drive Activity API** for the actor/action evidence Google makes available.

Use it to find recent additions, inspect the largest known files, combine metadata filters, review sharing details, or follow a folder's changes. A local SQLite index makes repeated searches and recorded-history review possible without requesting every file again. Real synchronization contacts Google; demo mode uses a separate synthetic workspace.

The app runs directly on macOS with system frameworks. It has no Python service, embedded browser UI, hosted backend, analytics SDK, or third-party runtime packages. Authentication opens your default browser. The current scope is metadata and activity: it does not download file contents or change remote files.

## Current status

| Area | Status | What that means |
| --- | --- | --- |
| Native application | **Implemented / local preview** | SwiftUI windows, tables, sidebar, inspector, settings, charts, and keyboard commands. |
| Local indexing and search | **Implemented / tested** | Real SQLite integration and synthetic file/filter tests, including a 10,000-file scenario. |
| Google API integration | **Implemented / live validation not done yet** | Pagination, retries, changes, and Activity have synthetic service-response tests; no real account has been used for validation. |
| Desktop OAuth | **Implemented / live validation not done yet** | PKCE/state and a real local loopback callback are tested; Google consent and Keychain token lifecycle still need a real account. |
| Folder notifications | **Implemented / delivery not verified** | Native rules and cooldown behavior are present; actual macOS notification delivery needs testing. |
| Historical evidence | **Implemented / locally tested** | Browse folders and inspect last-observed metadata at a chosen cutoff. Missing ancestors and uncertain historical access remain explicit. |
| Distribution | **Not done yet** | Local ad-hoc signed build only; no Developer ID signing, notarization, or downloadable production release. |

Detailed evidence and limits are in [Verification](docs/VERIFICATION.md) and the [native migration matrix](docs/PARITY.md). “Implemented” does not mean every real-account scenario has passed.

## Native app screenshots

These are direct captures from the native macOS app using synthetic files and `example.test` identities. They contain no connected Google account or private Drive inventory.

### Welcome and account setup

![Drive Explorer welcome screen with project logo](docs/screenshots/welcome.png)

Start with the isolated demo or configure your own Desktop OAuth client.

### Largest files and metadata inspector

![Largest files with metadata inspector](docs/screenshots/largest-files.png)

Compare known file size and quota usage while keeping owner, creation time, modification time, and local discovery separate.

### Advanced search

![Compound metadata filters](docs/screenshots/advanced-search.png)

Combine filters and save useful searches. Local metadata filtering supports fields that Google does not offer as server-side query operators.

### Activity evidence

![Actor-filtered activity](docs/screenshots/activity.png)

Review source-labelled records and inspect raw evidence. Unknown actors and incomplete coverage remain visible.

### Observed hierarchy at a cutoff

![Native observed-history folder browser](docs/screenshots/observed-history.png)

Browse retained snapshots with their observation times, original metadata, and explicit uncertainty about existence and access.

### Storage overview

![Storage charts in dark appearance](docs/screenshots/storage-dark.png)

Group known storage by type, direct parent, or Drive. Missing sizes stay **Unknown**; Workspace documents are not silently counted as zero-byte files. A [light appearance capture](docs/screenshots/storage.png) is also available.

## What it does

| Workspace | Current capabilities |
| --- | --- |
| Explorer | My Drive, shared-with-me and Shared Drive views; folder outline, table, clickable ancestor breadcrumbs, shortcut target details, and opening real items in Google Drive. |
| Advanced search | Name, ID, MIME type, extension, owner, parent, Drive, byte ranges, date ranges, trash state, saved searches, and a separate paginated Google query. |
| Newest items | Sort by creation, modification, local discovery, or recorded activity; inspect upload evidence when the API exposes it. |
| Largest files | Sort the loaded index by size or quota usage, with explicit unknowns and deterministic tie-breaking. |
| Activity | Filter actors, actions, targets and times; inspect raw source records, related file snapshots, and labelled possible correlations. |
| Observed history | Browse the last observed hierarchy at an RFC3339 cutoff, search the current level, and inspect original snapshot metadata. |
| Storage | Native charts and summaries by file type, direct parent, or Drive; indexed descendant totals. |
| Sharing | Inspect returned permission roles, public/domain grants, ownership details, and sharing-related activity. This is not a complete effective-access audit. |
| Watches | Folder/action rules, cooldown and batched notifications while the app is running; optional 60-second polling. |
| Export | Displayed file results or filtered Activity in CSV, JSON or JSONL, using native save panels. |
| Appearance | System, light or dark; native resizable panes, contextual actions and keyboard commands. |

## Build and run

Use macOS 14 or later and a Swift 6 toolchain with the macOS SDK. Development was verified on Apple silicon with Swift 6.4 and the macOS 27 SDK; older OS/toolchain and Intel compatibility have not been run.

```sh
git clone https://github.com/hideouts-io/drive-explorer-swift.git
cd drive-explorer-swift
./script/test.sh
./script/build_and_run.sh
```

The second command builds Release, derives all macOS icon sizes from the canonical Drive Explorer logo, creates and ad-hoc signs the native bundle, then launches it. `dist/DriveExplorer.app` is a local symbolic link to the verified bundle in the build cache; `dist/DriveExplorer.zip` is the portable archive. The Codex Run action uses the same script. The generated app and build intermediates go to `~/Library/Caches/DriveExplorerBuild` because this machine's Documents file provider attaches metadata that can invalidate strict signature checks on application and test bundles. Only generated application-bundle extended attributes are cleared before signing.

The `.app` is for local use. It is not notarized or signed with a Developer ID; do not present it as a distributable release. The build does not install the app or modify Google Drive.

Choose **Explore demo** to use synthetic data without credentials. Demo is a separate SQLite workspace; its files do not open in Google Drive. The app remembers demo mode, saved searches, watch rules, notification preference and appearance.

## Connect your Google account

1. In your own [Google Cloud project](https://console.cloud.google.com/), enable **Google Drive API** and **Google Drive Activity API**.
2. Configure the OAuth consent screen/audience. For an external app in Testing, add your account as a test user. Organizational policy can require administrator approval. Google may require verification for broader distribution.
3. Create an OAuth client of application type **Desktop app** and download its JSON. A Web application client, service-account key, or the old Python app's Web client configuration is not interchangeable.
4. Open **Drive Explorer → Settings** (`⌘,`), choose **Import Desktop client JSON**, and select that file. Do not paste credentials into chat or commit them.
5. Choose **Connect Google account**. Your default browser opens Google's consent page. The app uses an ephemeral `127.0.0.1` port, `/oauth/callback`, state validation, and S256 PKCE. No public callback service or custom URL scheme is required. Sign-in times out after three minutes.
6. Return to the app and choose **Refresh** (`⌘R`). Wait for the initial full metadata baseline and Activity seed. The status bar shows progress; cancel at any time. Review any coverage gaps before interpreting results.

Scopes are `drive.metadata.readonly` and `drive.activity.readonly`. The app reads metadata/activity, not file contents, and cannot rename, share, upload, or delete Drive files. Google server-side `name contains` semantics differ from local substring search. MIME and owner-email queries on Google are exact; size, extension and local discovery filters require the local index.

Access/refresh tokens and imported client configuration are in macOS Keychain under service `local.driveexplorer.oauth`. An installed application's client configuration is not a confidential server secret. Disconnect deletes stored tokens; it does not revoke Google's grant or delete cached files. Google account permissions can be revoked separately through your Google account security settings. Reconnect if a token expires or is revoked. See Google's [native OAuth guide](https://developers.google.com/identity/protocols/oauth2/native-app) for current policy and setup details.

## Using the explorer

- `⌘1` All files, `⌘2` Newest items, `⌘3` Largest files, `⌘4` Activity, `⌘5` Storage, `⌘6` Sharing, `⌘7` My Drive, `⌘8` Watches, `⌘9` Observed history.
- `⌘⇧F` toggles the advanced filter builder. Filters combine with AND. Dates use complete RFC3339 timestamps, for example `2026-09-01T00:00:00Z`. Saved searches store filters; sort order is chosen independently.
- Table headers or the sort picker choose ordering. Missing sizes stay last in either direction. Equal values use name and then file ID as stable secondary keys.
- Double-click folders to browse them; click any known ancestor in the breadcrumb trail to navigate back. Shared Drive roots keep their own identity, and missing parents or cycles remain labelled. The sidebar expands known folder children. File context menus open Google Drive, show activity, or watch a folder. Shortcuts expose their target ID in the inspector; inaccessible or unindexed targets are labelled.
- The inspector separates owner, creation, modification, first discovery, quota usage and action evidence. Snapshot details reconstruct paths using only ancestor snapshots observed by that cutoff, with explicit coverage limits. An owner is never assumed to be an uploader. Activity actors can be a `people/...` resource, “Me,” or unavailable; the app does not request additional People scopes just to resolve names.
- **Observed history** (`⌘9`) loads the newest recorded snapshot for each item at or before your RFC3339 cutoff. Browse a folder by double-clicking it or selecting **Browse observed folder**, return with the breadcrumbs or **All observed items**, and search names or exact IDs within the displayed level. The inspector shows the observation timestamp and original metadata. The toolbar export is disabled here; historical results are not substituted with current file exports. Old observations can remain after removal or access loss, so this view does not prove the item still existed or was accessible at the cutoff.
- Activity searches the latest 10,000 cached source records; the visible label states that limit. Metadata search covers the loaded whole local index. A Google search follows all returned pages, checks `incompleteSearch`, and does not insert search-only results into the durable baseline.
- Export the displayed file results or filtered Activity records using CSV, JSON, or JSONL. CSV protects formula-leading cells. Exports may contain file names, account identifiers, sharing details and raw evidence; review before sharing.
- Watches match a folder's indexed descendants and recorded move parents. Notifications batch new source records, accumulate during cooldown, and require both macOS notification permission and the app to remain running. Polling is every 60 seconds when enabled; it is not a background daemon or a transfer queue.

## Data and architecture

`DriveCore` contains value models, pure search/event/export transformations, a SQLite actor, the Google HTTP actor, and the collector. The native executable owns UI state, Keychain/OAuth, loopback callbacks, panels and notifications. Files are split by responsibility. Foundation, SwiftUI, Charts, Security, CryptoKit, Network, UserNotifications, AppKit and system SQLite are the only runtime dependencies.

SQLite schema version 2 stores files, scope membership, staged baselines, cursors, snapshots, events and preferences. Baselines are promoted transactionally only after all pages succeed; the pre-scan start token closes the scan/change gap. Each Changes page commits records and its cursor together. Interrupted baselines restart; committed change pages resume. Activity checkpoints advance only after the scope's complete pagination, with a five-minute overlap and source deduplication. Transient requests retry with warnings; persistent errors remain visible. HTTP 410 requires an explicit index rebuild.

Caches are under `~/Library/Application Support/DriveExplorer`, split between `Demo` and an account directory keyed by a hash of the authenticated Drive root ID. Tokens never go into SQLite. Metadata databases are not encrypted by the app; FileVault protects the disk. **Clear history** deletes events/snapshots in the current workspace. **Rebuild local index** clears cached files, cursors and evidence and preserves saved searches/watch rules; in demo it restores the synthetic dataset. These controls never mutate Google Drive.

The native project was developed alongside a separate Python/React reference; that application and its database are not required to build or run this repository. [Source hashes](docs/baseline-sha256.json) and the verification report document preservation. [Research and license notes](docs/RESEARCH.md) describe the repositories and official API documentation used.

## Understanding the evidence

| Evidence | What it can support | What it does not prove |
| --- | --- | --- |
| File metadata | Current returned name, parents, owner, size and timestamps. | The owner is not necessarily the uploader or person who last moved it. |
| Drive Changes | A file or visibility change observed in the change stream. | A removed record does not, by itself, prove deletion or identify an actor. |
| Drive Activity | Actions, actors and time or time ranges exposed for accessible targets. | Missing activity is not proof that no action occurred; actors may be unresolved. |
| Local discovery | When this app first indexed an item. | When the item was originally uploaded to Google Drive. |
| Observed snapshots | Metadata recorded locally and paths reconstructed from ancestors observed by the same cutoff. | A complete historical tree, continuous visibility, or exact location at Google's action time. |
| Possible correlation | Records near one another that may be useful to review together. | Causation or a confirmed match between separate sources. |

The initial Activity seed is seven days under My Drive and each accessible Shared Drive ancestor, with a five-minute overlap on later polls. Shared-with-me activity outside those roots may be absent. The Activity screen loads the latest 10,000 cached source records and displays that limit. These are coverage boundaries, not a complete audit log of an organization.

## Privacy and local data

- **Credentials:** Desktop client configuration and tokens are stored in macOS Keychain, not the repository or SQLite database. There is no shared OAuth client bundled with the project.
- **Network:** Live mode contacts Google's OAuth, Drive, and Drive Activity endpoints. Choosing Open in Google Drive opens a validated Google Drive/docs URL in your browser. There is no project telemetry service.
- **Cache:** Metadata, actor identifiers, permissions, raw activity, and snapshots can be sensitive. The local database is not encrypted by this app; its disk protection depends on macOS and your FileVault configuration.
- **Exports:** CSV formula-leading cells are protected, but exports are not anonymized. Review filenames, email addresses, file IDs, permissions and raw evidence before sharing.
- **Notifications:** Folder alerts can expose information on the desktop. Manage their visibility in macOS notification settings.
- **Disconnect:** Removes the stored token, not the cached metadata, imported client configuration, or Google-side authorization grant. Clear controls and Google account permissions are separate operations.
- **Removal:** Quit the app and remove the generated bundle/archive to remove the executable. To remove stored data too, separately remove `~/Library/Application Support/DriveExplorer`, `~/Library/Caches/DriveExplorerBuild`, and the `local.driveexplorer.oauth` entries in Keychain Access. This removes local history; it does not delete Google Drive files or revoke the Google-side grant.

## Planned work — not done yet

This is the working roadmap. Unchecked items are **not done yet** and have no promised delivery date.

- [ ] **Real-account validation:** consent, refresh/revocation, reconnect, account isolation, My Drive and Shared Drive synchronization, restricted permissions, API quotas and failures.
- [ ] **Notification validation:** permission grant, visible delivery, cooldown accumulation, restart behavior, and long-running polling under real API load.
- [x] **Observed hierarchy browser:** navigate retained metadata at a chosen cutoff, with missing-ancestor labels, per-item observation times, search, and raw inspection. Historical existence/access remains unknown; dedicated historical exports are not implemented.
- [ ] **Large-drive profiling:** measure memory, cancellation and UI latency beyond the current 10,000-file scenario; improve query/paging design where measurements justify it.
- [x] **Ancestor navigation:** clickable breadcrumbs with shared-root, unknown-parent, and cycle handling.
- [ ] **Accessibility audit:** complete the full keyboard/VoiceOver review across all screens.
- [ ] **Compatibility:** run on the declared older macOS versions and Intel hardware, then document the tested matrix.
- [ ] **Distribution:** reproducible release automation, Developer ID signing, notarization and verified release artifacts.
- [ ] **Optional Workspace Events integration:** assess Pub/Sub subscriptions and renewal as an alternative monitoring source; currently there is no adapter or always-on agent.

Additional ideas remain exploratory: explicit Python-cache import, an account switcher, optional People-name resolution, and encrypted local metadata. They are not available today. Remote mutation, file-content downloads, and Google Drive for desktop transfer-queue monitoring are outside the current read-only scope.

## Testing and verification

Run `./script/test.sh` for the Swift Testing suite and `./script/build_and_run.sh` to build and inspect the actual packaged app. The current verified suite has **29 passing tests**, including real SQLite and loopback integrations plus synthetic Google responses. A passing test suite does not validate a live Google account.

[Verification](docs/VERIFICATION.md) is the detailed record of checks, screenshots, and remaining gaps. [Research](docs/RESEARCH.md) lists API documentation and projects that informed the design. [Parity](docs/PARITY.md) compares native behavior with the separate development reference.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Swift or SDK unavailable | Install/select an Apple developer toolchain with Swift 6 and a macOS SDK; check `swift --version` and `xcode-select -p`. |
| Client JSON rejected | Use a **Desktop app** OAuth client; a Web client or service-account key is not compatible with this flow. |
| Google denies consent or an API returns 403 | Check API enablement, test-user access, organization policy and the error details; permission-limited scopes remain incomplete. |
| Browser sign-in times out | Start Connect again and finish within three minutes; the callback is a temporary loopback listener on this Mac. |
| Token revoked or refresh fails | Reconnect through Settings and review the Google grant. Do not paste tokens into issues. |
| Expired Changes cursor / HTTP 410 | Use the explicit **Rebuild local index** control after reviewing its confirmation; local evidence is cleared as described above. |
| File size, actor or parent unavailable | Google may omit it, or its scope may not be indexed. Review raw evidence and coverage rather than substituting a guess. |
| No folder notification | Keep the app running; check the watch rule, cooldown, indexed ancestry, polling and macOS permission. Real delivery remains unverified. |
| Build signing fails under a synced folder | Keep the default local build-cache path. The build script avoids file-provider metadata on generated bundles. |

## Repository structure

```text
Package.swift                         SwiftPM products and system SQLite dependency
Sources/DriveCore/                    Models, indexing, Google APIs, search and exports
Sources/DriveExplorer/App/            App entry point and keyboard commands
Sources/DriveExplorer/Stores/         UI session and cancellable operations
Sources/DriveExplorer/Services/       Keychain, OAuth and loopback callback
Sources/DriveExplorer/Views/          Native screens, inspectors and settings
Sources/DriveExplorer/Resources/      Canonical Drive Explorer logo
Sources/CSQLite/                      System SQLite module bridge
Tests/DriveCoreTests/                 Core and integration verification
script/                              Tests, icon conversion, packaging and launch
assets/                              Logo generation provenance
docs/                               Verification, research, parity and demo screenshots
```

The canonical logo is used by the README, welcome screen, and generated macOS app icon. Change that source PNG to update future builds; generated icon sizes and bundles are ignored by Git.

## Contributing

This project is in active development. Use issues for reproducible bugs or focused feature proposals and pull requests for reviewable changes. Describe what was tested with synthetic data versus a real Google account. Run the existing tests, inspect relevant native UI, and keep the read-only and evidence-coverage boundaries explicit.

Never attach OAuth JSON, tokens, real Drive caches, private exports, or unredacted account screenshots. If a report involves credentials, revoke them through Google and share only a sanitized reproduction. Use `example.test` identities and synthetic file IDs in fixtures.

## License

Released under the [MIT License](LICENSE), copyright © 2026 hideouts-io. This repository includes the app source, documentation, and project artwork under that license. The logo was generated for this project; its [generation prompt](assets/drive-explorer-logo.prompt.txt) is included.

Google Drive and related names belong to their respective owners. This is an independent project and is not affiliated with or endorsed by Google or Apple. Apple system frameworks and Google services remain subject to their own terms; references and their licenses are documented in [Research](docs/RESEARCH.md).
