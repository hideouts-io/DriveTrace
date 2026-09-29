# Verification report

Verified 2026-09-29 on macOS 27.0 (26A428), Apple silicon, Swift 6.4. This is a local native preview, not a live-account or distribution certification.

## Implemented and automated

`./script/test.sh` passes **27 Swift Testing tests**, zero failures. The XCTest wrapper prints “0 tests”; the following Swift Testing result is the actual 27-test run. Full output: `test-results.txt`.

Coverage includes:

- Real SQLite schema creation, version-1 migration/reopen, staged baseline visibility, atomic promotion, rollback on malformed Changes records, durable cursors, retained snapshots, observation-cutoff historical paths that exclude future ancestor names, overlapping scope membership, scope retirement and newer-schema rejection.
- Synthetic Google requests through URLSession/URLProtocol: multi-page file/Changes/Activity ingestion, restart from cursor, repeated tokens, incomplete scans, partial 403 failure, 401 refresh, 429 retry, repeated 503 exhaustion and cancellation.
- Exact actor/resource attribution, source deduplication, removal as inaccessibility, compound filters, query escaping, unknown-size ordering, cycles and unresolved paths.
- CSV, JSON and JSONL file/event exports, formula-leading cells, absent sizes, source/actor preservation, RFC3339 round-trips and offset-aware time comparisons.
- Desktop-client configuration rejection, S256 PKCE and state parameters; a real local TCP OAuth callback rejects the wrong state, accepts the right code, and terminates on cancellation. No Google token is used by these tests.
- A 10,000-file SQLite stage/promote/load/filter/sort scenario. The measured test duration is recorded in `test-results.txt`; it was approximately 0.4 seconds on this host. This is not a GUI benchmark or a million-file scalability claim.

## Packaged native app

`./script/build_and_run.sh` completes Release compilation, icon generation, ad-hoc signing and strict signature verification, archives the bundle and opens the actual app. Output: `build-results.txt`. `dist/DriveExplorer.app` links to the generated bundle under `~/Library/Caches/DriveExplorerBuild`; `dist/DriveExplorer.zip` contains the portable `.app`. Build-cache placement avoids this host's Documents file-provider metadata breaking code-signature verification.

The generated executable is arm64. Developer ID signing, notarization, sandbox distribution and Intel/older-macOS runs are **unverified / not supplied**. Source publication is separate from binary distribution; no signed/notarized release is supplied and the build does not install the app.

## Verified in the rendered native app

Computer-use checks used native accessibility identifiers, container IDs and app keyboard commands. The actual app, not a browser mockup, was inspected.

| Interaction | Observed result |
| --- | --- |
| Branding | Canonical PNG rendered on the welcome screen; bundled ICNS generated from the same image. |
| Onboarding → Explore demo | Clearly labelled separate synthetic workspace, 91 cached items and 160 source records. |
| File-name search `Launch` | 14 matching files. |
| Largest files and ascending/descending toggle | Descending starts with the 6.83 GB video; ascending starts with small known files; missing sizes remain unknown. |
| Compound filters | Extension `mov` plus minimum `1000000000` bytes gives six files. |
| Save search | “Large QuickTime videos” persisted in the sidebar across relaunches. |
| File inspector | File/quota size, owner, created/modified/discovery times, cached path, source records and snapshots displayed. |
| Activity actor filter `Alex` | 54 of the 160 loaded synthetic records, with source and actor labels. |
| Raw evidence | Selected action opened a native sheet containing the corresponding synthetic JSON payload. |
| Storage | Known size/quota summaries and chart rendered; 15 all-unknown Workspace items display Unknown, not a zero-byte total. Both light and dark appearances inspected. |
| Folder navigation/watch | My Drive → Design studio displayed 18 items and its breadcrumb; Watch folder created a rule shown in the native Watches editor with five-minute cooldown. |
| Native CSV save | Saved `/tmp/drive-explorer-demo-export.csv`; parsed 84 rows, largest size 6,828,300,000 bytes, blank missing-size fields. |
| Settings | Desktop OAuth import/connect controls, monitoring, appearance and local data controls rendered. No credentials entered and no notification permission granted during verification. |

Screenshots in `screenshots/` are direct captures from the Swift app: welcome, largest files, advanced search, activity, storage light and storage dark. They use synthetic names and `example.test` identities only. They were not composited or edited.

## Requires a live Google account

The following are implemented but cannot be called verified without a user-provided Desktop OAuth client and account consent:

- Google consent and access/refresh token issuance, Keychain save/unlock/refresh/reconnect, revoked grants, and account switching.
- Actual Drive/Shared Drive pagination, restricted metadata/permissions, Activity visibility, quotas, rate limits and API policy errors.
- Attribution availability and People's resource identities in the user's tenant.
- Long-running polling, network loss/restart under real API load, and native notification delivery with macOS permission.
- Opening accessible files/shortcuts in Google Drive. Demo deliberately does not navigate synthetic IDs to Google.

Use the setup steps in `../README.md`; never paste secrets into chat. These checks are the next integration stage, not evidence that the implemented code is already production-ready.

## Partial implementation / future work

- A full historical tree browser is future work. Per-file snapshots now include paths reconstructed only from ancestor observations at or before their local detection cutoff. Unknown ancestors are labelled; reconstruction does not prove continuous coverage, accessibility, or location at Google action time. Previous/current parent IDs remain direct evidence.
- Activity queries cover My Drive and accessible Shared Drive ancestors, seeded with seven days. Shared-with-me items outside those ancestors, events Google does not expose, and pre-seed history may be absent. Range events display their end time; the raw payload retains the original range.
- The visible Activity window loads the latest 10,000 records. Metadata queries operate on the full in-memory index; server-side size search is unsupported. Huge-drive memory/CPU behavior still needs profiling.
- Watches depend on indexed ancestry, visible Activity/Changes records, and the running app. Their actual notification delivery is unverified. There is no always-on agent, Workspace Events/Pub/Sub adapter, or Drive for desktop transfer queue.
- No Python-cache importer, simultaneous multi-account switcher, People-name enrichment, file-content preview/download, or mutation actions. A new native account connection starts a fresh baseline.
- Breadcrumbs show a path and root navigation, rather than a clickable button for every ancestor. Full VoiceOver coverage remains unverified.
- Cache data is local but not encrypted by the app. Disconnect removes tokens, not the Google-side grant or cached metadata; explicit clear controls and Google account security settings have separate purposes.

## Reference preservation

All **41 recorded baseline source files** match their pre-migration SHA-256 values. `baseline-verification.json` records zero changes. Runtime caches/dependencies and existing images were excluded from the original source manifest. The original Python/React application's own test results were read from its verification report; they were not rerun or misrepresented as Swift tests.
