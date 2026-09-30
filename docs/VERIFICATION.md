# Verification report

Verified 2026-09-29 on macOS 27.0 (26A428), Apple silicon, Swift 6.4. This is a local native preview, not a live-account or distribution certification.

## Implemented and automated

`./script/test.sh` passes **36 Swift Testing tests**, zero failures. The XCTest wrapper prints “0 tests”; the following Swift Testing result is the actual 36-test run. Full output: `test-results.txt`.

Coverage includes:

- Real SQLite schema creation, version-1 migration/reopen, staged baseline visibility, atomic promotion, rollback on malformed Changes records, durable cursors, retained snapshots, observation-cutoff historical paths that exclude future ancestor names, overlapping scope membership, scope retirement and newer-schema rejection.
- Synthetic Google requests through URLSession/URLProtocol: multi-page file/Changes/Activity ingestion, restart from cursor, repeated tokens, incomplete scans, partial 403 failure, 401 refresh, 429 retry, repeated 503 exhaustion and cancellation.
- Historical hierarchy cutoff queries across folder renames, child moves, removal, database reopen and history clearing; equivalent timezone offsets include the exact cutoff observation. Breadcrumb tests cover Shared Drive identity, duplicate names, cycles, unavailable parents and multiple-parent disclosure.
- Rejected malformed/reversed date and size ranges before local/remote queries, offset-aware numeric date sorting, cancelled sorting, prepared folder trees with cycle termination and unresolved paths.
- Exact actor/resource attribution, source deduplication, removal as inaccessibility, compound filters, query escaping, unknown-size ordering, cycles and unresolved paths.
- CSV, JSON and JSONL file/event exports, formula-leading cells, absent sizes, source/actor preservation, RFC3339 round-trips and offset-aware time comparisons.
- Desktop-client configuration rejection (malformed, Web, service account, invalid ID, oversize), optional secret and extra-field acceptance, S256 PKCE and state parameters; a real local TCP OAuth callback rejects the wrong state, accepts the right code, and terminates on cancellation. Token-envelope tests reject missing/wrong-type fields, invalid lifetime/type, empty tokens and either missing read-only scope without exposing credential values in errors. Offline sign-in requires a refresh token; renewal retains the previous refresh token when omitted or uses the returned replacement. This follows [Google’s native-app token and granted-scope contract](https://developers.google.com/identity/protocols/oauth2/native-app). No Google token or real Keychain token lifecycle is used by these tests.
- Watch batching against real SQLite: duplicate record IDs, moved-out parent evidence, cooldown boundary, pending records surviving reopen without acknowledgement, and atomic acknowledgement that preserves later queued records. Disabled rules do not become due; invalid stored delivery times fail explicitly. Authorization gating accepts authorized/provisional states and rejects denied/not-requested states before submission. This does not test macOS delivery.
- A 10,000-file SQLite stage/promote/load/filter/sort scenario. The measured test duration is recorded in `test-results.txt`; it was approximately 0.4 seconds on this host. This is not a GUI benchmark or a million-file scalability claim.

## Local performance measurements

Run `swift run -c release --scratch-path "$HOME/Library/Caches/DriveExplorerBuild" DriveBenchmarks`. It creates and removes its own synthetic temporary SQLite database; it never opens the account cache or Google APIs. [Machine-readable results](performance-results.json) record the workload and process peak memory.

On this host, 100,000 files (1,000 flat root folders, identical modification timestamps) took 2.30 s to stage/promote and 0.45 s to load files/facts. Modification-time sorting fell from **57.16 s to 0.18 s** after replacing per-record formatter construction/string normalization with Foundation ISO8601 format-style parsing and numeric date comparison. Size filtering took 0.012 s, navigation/path preparation 0.115 s, and cancellation of an in-flight sort 0.027 s. Peak process RSS was about 292 MiB, including the benchmark's input/loaded arrays and SQLite staging.

These are single-run synthetic core measurements, not GUI latency, a deep-tree stress test, API throughput or million-file guarantees. The app cancels superseded searches and prepares cached navigation off the main actor. Keyboard workflows were checked with the normal 91-item demo and a separate 25,000-item synthetic fixture in the actual universal app. The latter displayed 24,900 nonfolder items in Largest Files, one exact-name match for `24999`, and 100 root folders in My Drive. Observed input-through-accessibility-capture times were 3.28 s, 4.69 s and 1.44 s respectively; these include automation/settling overhead and are **not isolated frame latency**. Idle RSS after these checks was 386.9 MiB. [UI scale results](ui-scale-results.json) preserve these observations. The original 91-item demo was saved and restored byte-for-byte, with its record count rechecked; the temporary synthetic fixture was removed.

The measured bounds do not cover deep folder hierarchies, huge historical snapshot sets, million-item indexes or live API throughput. Full VoiceOver speech review remains unverified; keyboard and accessibility-tree checks cannot establish spoken-output usability.

## Packaged native app

`./script/build.sh` builds arm64 and x86_64 Release slices, stages a fresh bundle, copies the original blue Dock icon, ad-hoc signs and checks every architecture. It verifies the bundle identity, minimum OS, icon, canonical PNG and license; then extracts the ZIP into a temporary directory and repeats verification. `./script/build_and_run.sh` closes the existing app, runs packaging and opens the actual app. Build-only packaging refuses to overwrite a running app. `dist/SHA256SUMS` contains the archive checksum. Output: `build-results.txt`. `dist/DriveExplorer.app` links to the generated bundle under `~/Library/Caches/DriveExplorerBuild`; `dist/DriveExplorer.zip` contains the portable `.app`. Build-cache placement avoids this host's Documents file-provider metadata breaking code-signature verification.

The generated executable is universal arm64/x86_64; both slices compile and pass signature/architecture checks. Native launch is verified on Apple silicon. Developer ID signing, notarization, sandbox distribution and Intel/older-macOS runtime are **unverified / not supplied**. A read-only identity check found zero Developer ID Application identities on this host. No signing credentials were requested or exported. Source publication is separate from binary distribution; no signed/notarized release is supplied and the build does not install the app.

### Distribution workflow preparation — partial

`script/notarize.sh` requires an explicit Developer ID Application certificate SHA-1 and an existing notarytool Keychain profile. It checks the identity before signing/uploading, operates on a separate copy, requires Apple's `Accepted` result, staples/validates the ticket, and assesses both the app and the extracted final archive with Gatekeeper. It preserves private failure diagnostics locally and never publishes a release. Setup and invocation are in the [README distribution instructions](../README.md#preparing-a-signed-distribution--not-verified-yet).

Verified locally: zsh syntax; missing arguments, malformed certificate input and absent signing identity fail before upload; the Developer ID code requirement rejects the current ad-hoc preview; a temporary copy accepts ad-hoc hardened-runtime signing and passes both-architecture/resource/signature checks. The original preview's executable hash is unchanged afterward. No certificate, password or token was requested/exported, no notarytool authentication was attempted, and nothing was uploaded to Apple. The real Developer ID, timestamping, Apple processing, stapling and Gatekeeper success paths remain **unverified**. Script preparation does not complete the distribution roadmap.

## Verified in the rendered native app

Computer-use checks used native accessibility identifiers, container IDs and app keyboard commands. The actual app, not a browser mockup, was inspected.

| Interaction | Observed result |
| --- | --- |
| Branding | Canonical red PNG rendered on the welcome screen; the original blue Dock ICNS is restored byte-for-byte from the preserved early app bundle and checked during packaging. |
| Onboarding → Explore demo | Clearly labelled separate synthetic workspace, 91 cached items and 160 source records. |
| File-name search / keyboard | Cmd-F focused search and `Launch` returned 14 matches. Cmd-F from Activity opened All files and focused search; `Research` returned eight. Cmd-3/5/6/7/8/9 opened the expected screens after navigation caching. |
| Invalid filters | Invalid Created date displayed a specific RFC3339 error and disabled Save search. Clear search removed invalid date and negative size inputs, restoring 89 active demo items. Activity invalid dates displayed an explicit range error. Sort buttons expose direction and current value; watch toggles identify their folder. |
| Largest files and ascending/descending toggle | Descending starts with the 6.83 GB video; ascending starts with small known files; missing sizes remain unknown. |
| Compound filters | Extension `mov` plus minimum `1000000000` bytes gives six files. |
| Save search | “Large QuickTime videos” persisted in the sidebar across relaunches. |
| File inspector | File/quota size, owner, created/modified/discovery times, cached path, source records and snapshots displayed. |
| Activity actor filter `Alex` | 54 of the 160 loaded synthetic records, with source and actor labels. |
| Raw evidence | Selected action opened a native sheet containing the corresponding synthetic JSON payload. |
| Storage | Known size/quota summaries and chart rendered; 15 all-unknown Workspace items display Unknown, not a zero-byte total. Both light and dark appearances inspected. |
| Folder navigation/watch | My Drive → Design studio displayed 18 items and its breadcrumb; Watch folder created a rule shown in the native Watches editor with five-minute cooldown. |
| Observed history | Cmd-9 loaded 91 synthetic observations; invalid RFC3339 showed a specific error, a pre-index cutoff showed zero items, and Now restored the set. Searched Archive, browsed its 17 recorded children (including a trashed item), inspected raw observation JSON, and navigated to Research using its breadcrumb. |
| Current breadcrumbs | Double-clicked Archive from file search, then clicked Research in its trail; the current Research view showed 18 items. |
| Native CSV save | Saved `/tmp/drive-explorer-demo-export.csv`; parsed 84 rows, largest size 6,828,300,000 bytes, blank missing-size fields. |
| Guided connection | Opened from Settings, inspected all five steps and scope URLs, verified missing-client sign-in and demo synchronization are disabled. Imported a synthetic invalid Web-client JSON through the native sheet: actionable error stayed in the guide and the client remained not imported. Updated step 4 explains selecting both read-only permissions and preserving a prior saved sign-in on incomplete consent; checked in the rendered app. No credentials entered. |
| Settings | Permission status read from macOS; Test notification without authorization displayed a specific corrective message in the pinned, visible error panel. Check permission refreshed the state. No permission prompt accepted or Google account used. Banner delivery and the foreground delegate remain unverified at runtime. |

Screenshots in `screenshots/` are direct captures from the Swift app: welcome, largest files, advanced search, activity, observed history, storage light, storage dark and Google setup. They use synthetic names and `example.test` identities only. They were not composited or edited.

## Requires a live Google account

The following are implemented but cannot be called verified without a user-provided Desktop OAuth client and account consent:

- Google consent and access/refresh token issuance, Keychain save/unlock/refresh/reconnect, revoked grants, and account switching.
- Actual Drive/Shared Drive pagination, restricted metadata/permissions, Activity visibility, quotas, rate limits and API policy errors.
- Attribution availability and People's resource identities in the user's tenant.
- Long-running polling, network loss/restart under real API load, and native notification delivery with macOS permission.
- Opening accessible files/shortcuts in Google Drive. Demo deliberately does not navigate synthetic IDs to Google.

Use the [setup steps](../README.md#connect-your-google-account); never paste secrets into chat. These checks are the next integration stage, not evidence that the implemented code is already production-ready.

## Partial implementation / future work

- The Observed history browser navigates the latest available per-file snapshots at a chosen cutoff. It includes retained observations of removed/inaccessible items and does not model their historical existence or accessibility. Per-file snapshot details reconstruct ancestor paths at their local detection cutoff. Unknown ancestors are labelled; reconstruction does not prove continuous coverage, accessibility, or location at Google action time. Previous/current parent IDs remain direct evidence.
- Activity queries cover My Drive and accessible Shared Drive ancestors, seeded with seven days. Shared-with-me items outside those ancestors, events Google does not expose, and pre-seed history may be absent. Range events display their end time; the raw payload retains the original range.
- The visible Activity window loads the latest 10,000 records. Metadata queries operate on the full in-memory index; server-side size search is unsupported. A reproducible 100,000-file core benchmark covers SQLite, sorting, filtering, navigation preparation and cancellation. A 25,000-item native UI check measures visible result completion and process RSS with automation overhead; deeper/larger hierarchy/history behavior remains unverified.
- Watches depend on indexed ancestry, visible Activity/Changes records, and the running app. Their cooldown/persistence logic is tested, but actual notification delivery is unverified. The app queues all eligible watches before attempting submissions and checks current macOS authorization before each submission. Denied/not-requested permission leaves queued batches unacknowledged. Permission can still change after that check; OS acceptance does not establish visible delivery. A retained app delegate requests foreground banner/list/sound presentation following [Apple’s notification delegate API](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate). A crash after the OS accepts a request and before acknowledgement can cause repeat delivery; exactly-once notification delivery is not claimed. There is no always-on agent, Workspace Events/Pub/Sub adapter, or Drive for desktop transfer queue.
- No Python-cache importer, simultaneous multi-account switcher, People-name enrichment, file-content preview/download, or mutation actions. A new native account connection starts a fresh baseline.
- Known breadcrumb ancestors are clickable in current folders and Observed history. Full VoiceOver coverage remains unverified. Historical browsing loads its snapshot set into memory; huge-history scalability and dedicated historical exports are not implemented.
- Cache data is local but not encrypted by the app. Disconnect removes tokens, not the Google-side grant or cached metadata; explicit clear controls and Google account security settings have separate purposes.

## Reference preservation

All **41 recorded baseline source files** match their pre-migration SHA-256 values. `baseline-verification.json` records zero changes. Runtime caches/dependencies and existing images were excluded from the original source manifest. The original Python/React application's own test results were read from its verification report; they were not rerun or misrepresented as Swift tests.

## Guided live validation — not performed yet

The app is ready for a user-controlled Desktop OAuth configuration. Keep the downloaded JSON on your Mac and import it through Settings → Connect Google Drive → step 3; do not upload it to an issue or chat. Complete Google consent yourself in your browser. No live validation is recorded by these instructions alone.

1. **Connect:** enable both APIs and configure a Desktop client as described in the README. Import it, choose Sign in with Google, and complete browser consent. Confirm the app returns from sign-in without an error.
2. **Baseline:** choose Run synchronization in step 5 (or Refresh in the explorer). Record privately whether the status says complete or lists coverage gaps. Compare a small set of existing My Drive and Shared Drive items against the Google Drive website: IDs, names, parent folders, known sizes, and returned permissions. Do not equate missing API fields with an empty value.
3. **Attribution:** inspect activity on those same existing items. Compare available actor/action/time evidence, keeping the owner and uploader separate. Record absent or unresolved actors as a coverage limit.
4. **Persistence:** quit/reopen, verify the same account cache and saved searches, then refresh again. After normal access-token expiration, verify automatic refresh; never modify the system clock or print the token to test it.
5. **Failure and reconnect:** test a temporary network interruption and cancellation. To test revocation, intentionally revoke this app's grant in your Google account, confirm the error is visible, and reconnect. This step requires your deliberate account action.
6. **Notifications and watches:** first, without Google, open Settings → Monitoring, enable Native watch notifications and grant macOS permission if wanted. Choose Test notification and confirm the synthetic banner or Notification Center entry yourself. Repeat with the app foreground/background and check Focus/alert settings if it is absent. The acceptance message alone is not proof of display. Then add a rule to a controlled Drive folder and use known activity to check delivery, cooldown batching and restart behavior. Deny notification permission in macOS to verify pending records remain queued; allow it again, choose Check permission and refresh Drive to retry. Keep filenames/private notification content out of shared reports.
7. **Account separation:** if you have a second test account, connect it and confirm the index is separate. Return to the first account and confirm its history remains isolated.

Record each check as verified, failed, permission-limited, or not tested. Keep detailed evidence locally; publish only sanitized outcomes. Never label a partial initial scan as complete or a synthetic fixture test as a real-account result.

## Remaining gates and research order

The current plan is **not complete**. The next external gate is user-controlled Google setup/consent through the native guide, followed by the live checks above. Keep all credential JSON and tokens on the Mac. Notification permission and observed delivery need a deliberate local test in Settings, followed by a live watch check. Intel and older macOS runtime need suitable machines/VMs. Signed distribution needs a Developer ID Application identity and a user-configured notarization credential profile; neither is supplied here.

Deep-history/extreme-scale profiling remains beyond the bounded 100,000-file core and 25,000-item UI workloads. Full VoiceOver spoken-output review remains unverified and needs a listening review; AX text and keyboard navigation alone do not prove it. The optional Workspace Events feasibility assessment is in the README; its adapter remains deferred. No new competitor comparison or research-inspired feature implementation has begun.
