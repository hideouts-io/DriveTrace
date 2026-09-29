# Research and license notes

Reviewed 2026-09-29. Repository activity was checked using GitHub's public repository metadata; timestamps are a point-in-time indication of maintenance, not an audit of the projects.

| Reference | Observed maintenance / license | Design decisions informed |
| --- | --- | --- |
| [rclone Drive backend](https://github.com/rclone/rclone/blob/master/backend/drive/drive.go) and [Drive documentation](https://rclone.org/drive/) | Not archived; last push reported 2026-09-29; MIT | Keep file size, native-document availability and quota usage separate; use partial field masks and explicit Shared Drive scopes; do not assume names are unique; guard folder cycles and preserve shortcut targets. |
| [CodeEdit native project navigator](https://github.com/CodeEditApp/CodeEdit/tree/main/CodeEdit/Features/NavigatorArea/ProjectNavigator) | Not archived; last push reported 2026-08-18; MIT | Native outline/table navigation, keyboard commands and selection-dependent contextual actions. Its NSOutlineView source was inspected; this smaller app uses SwiftUI OutlineGroup/Table instead of importing its editor architecture. |
| [Google Workspace Python samples](https://github.com/googleworkspace/python-samples/blob/main/drive/activity-v2/quickstart.py) | Not archived; last push reported 2026-06-23; Apache-2.0 | Installed-app browser flow, Activity response structure, distinction between current, known and unknown actors, and time ranges. This app stores tokens in Keychain and normalizes individual actions instead of presenting a consolidated activity as a single proven actor/action. |

These are design/API references. No third-party application source was copied, vendored, or linked into the executable. There are no package dependencies. Repository licenses do not grant rights to Google's brand or imply endorsement. The project logo is original generated artwork, with its prompt in `../assets/drive-explorer-logo.prompt.txt`. The canonical PNG is `../Sources/DriveExplorer/Resources/drive-explorer-logo.png`; AppKit resizes it for the macOS icon set. The app does not use Google's logo. Project source, documentation, and artwork use the MIT license in `../LICENSE`.

## Official API references

- [OAuth for installed/native applications](https://developers.google.com/identity/protocols/oauth2/native-app): Desktop client, browser authorization, ephemeral loopback redirect, state, PKCE, refresh tokens.
- [Drive search terms](https://developers.google.com/workspace/drive/api/guides/ref-search-terms): supported query fields, quoting and operators; there is no server-side arbitrary file-size query in this implementation.
- [Files.list](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/list): pagination, corpus selection, Shared Drive support, `incompleteSearch` and field masks.
- [Files resource](https://developers.google.com/workspace/drive/api/reference/rest/v3/files): optional size/quota/owner/shortcut metadata. Absence is preserved as unknown.
- [Retrieve changes](https://developers.google.com/workspace/drive/api/guides/manage-changes): start token before scanning, chronological pages, final `newStartPageToken`; removal is not an actor-attributed deletion proof.
- [Activity.query](https://developers.google.com/workspace/drive/activity/v2/reference/rest/v2/activity/query): ancestor scope, filters, pagination and no-consolidation strategy. The collector seeds seven days under My Drive and each accessible Shared Drive and records partial failures separately.
- [Activity data model](https://developers.google.com/workspace/drive/activity/v2/datamodel): actions, targets, actors and time ranges; raw responses remain inspectable.

Workspace Events subscription/Pub/Sub integration is intentionally future work in the native app. The current product is explicit desktop polling and does not expose Google Drive for desktop's upload/download queue or transfer progress.
