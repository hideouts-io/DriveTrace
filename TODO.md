# DriveTrace improvement plan

This is the actionable plan. The [README roadmap](README.md#planned-work--not-done-yet) summarizes product scope; [VERIFICATION.md](docs/VERIFICATION.md) owns the evidence and remaining live checkpoints. The overall plan is **not complete**.

Statuses describe each item's stated boundary: **planned** has not been implemented, **partial** has unfinished implementation or validation, **verified** passed the specified bounded checks, and **blocked** needs an external prerequisite. A verified local component does not establish live Google behavior. Effort estimates are engineering sessions: **S** approximately one session, **M** two to four, **L** five or more, excluding external waiting and review.

Keep the original blue branding, SwiftUI design, Keychain storage and existing permission boundaries. Use isolated synthetic workspaces for independent checks. Keep credentials, real caches, downloaded content, private exports and generated builds out of Git. The current request authorizes a validated source commit, branch push and review PR with the necessary existing CI inputs. Merge, release, deployment, visibility changes and permanent deletion remain separate decisions. GitHub validation must run at the published candidate; local checks do not substitute for required hosted checks.

The published batch-cleanup implementation checkpoint `0f30112` passes native Xcode 26.6 CI with 144 tests in seven suites and strict CSQLite compilation, as well as 144 local tests. Its fresh Swift CodeQL result **failed** with one extraction ambiguity despite all 50 owned production Swift files being represented. This evidence-only follow-up preserves identical production/test/workflow inputs; current-head checks still govern integration. Preserve the gate and [hosted evidence](docs/VERIFICATION.md#hosted-validation-checkpoint). This does not complete the product plan or authorize integration.

## Critical deferred bug

### P0 — Modifier-click selection: BROKEN AND DEFERRED

**Status: partial — user-confirmed failure, explicitly deferred. Effort: M after reproduction.**

- **Problem / benefit:** Shift-click and Command-click failed the user's native check. Reliable selection is essential before batch downloads or Trash review; keyboard Shift+Down success does not prove either mouse gesture works.
- **Implementation:** Follow the existing [reproduction and return checklist](docs/VERIFICATION.md#open-bug--modifier-click-selection). Inspect `Views/ExplorerView.swift` (`FileTable`), `Stores/AppModel.swift` selection, and batch-action stores. Reproduce first; do not presume cell gestures or polling are the cause. Preserve selection for right-click actions and background refresh.
- **Dependencies / permissions / blocker:** No new Google permission. The user's explicit deferral is active; do not repair or silently count this as complete during other work.
- **Acceptance / validation:** Native range selection, nonadjacent addition/removal, right-click on selected/unselected rows, polling preservation, and exact reviewed batch IDs. Use disposable metadata and cancel Trash review; this plan does not authorize a new mutation.

## Current bounded milestones

### P1 — Keep generated download names within the local byte limit

**Status: verified for synthetic discovery/export requests and real filesystem saves; live conversions remain unverified. Effort: S.**

- **Problem / benefit:** Adding a duplicate suffix or export extension to a valid 240-byte name previously failed. A duplicate folder could consequently lose its traversal.
- **Implementation:** `DriveCore/Downloads.swift` reserves bytes for generated extensions and shortens the original stem at whole Unicode character boundaries. `DownloadPlan.swift` reuses that rule for collision suffixes, preserving the extension, canonical collision keys and exclusive saves. Already valid short names stay unchanged; original over-limit names and impossible suffix/grapheme fits remain explicit failures.
- **Dependencies / permissions / blockers:** Existing Foundation/filesystem and download transport; no new dependency or permission. Independent checks need no account. Live Google exports require the existing management connection and the exact disposable fixture location.
- **Acceptance / validation:** `DownloadNameTests.swift` follows discovery through batch saves for long ASCII/Unicode duplicates, duplicate folders with distinct children, Docs/Sheets and short names. Exact bytes and report paths survive; all names fit the byte limit, export endpoint/MIME is correct, existing content is unchanged and impossible boundaries fail. This does not establish live Office-document conversion or external-volume behavior.

### P1 — Preserve saved downloads when temporary cleanup fails

**Status: partial — real filesystem checks, complete loopback transport/batch cleanup-warning continuation and earlier native accessibility presentation pass; full layout and live Google behavior remain unverified. Effort: S.**

- **Problem / benefit:** Staging cleanup can fail after bytes have been committed. Reporting the item as a failed download hides the saved file and invites an unnecessary repeat.
- **Implementation:** `DriveCore/Downloads.swift` distinguishes successful destination commit from staging/transport temporary cleanup, retaining the destination and original causes. `BatchDownloads.swift` records downloaded outcomes with explicit cleanup warnings using the existing report schema. `Views/BatchDownloadView.swift` displays the warning with the saved result. Stop rather than retry a committed download.
- **Dependencies / permissions / blockers:** Existing Foundation/filesystem facilities; no new dependency or Google scope. A real filesystem obstruction reproduces the local boundary without Google credentials. The report-only production-view helper passes full accessibility reads, but usable native layout capture remains unavailable. The crashed multi-view helper is retired; its precise accessibility-recursion trigger remains unresolved in the verification report.
- **Acceptance / validation:** Post-commit filesystem failures preserve exact saved/source bytes and report the temporary path/cause; JSON retains the downloaded outcome and warning. The full loopback batch test forces real transport-temporary cleanup denial after commit, downloads the next item, and confirms no repeated request or failed saved outcome. Check warning layout, accessibility and Finder access natively; keep live Google validation separate.

### P1 — Keep download outcomes when the private report cannot be persisted

**Status: partial — report-copy persistence/model checks, complete retained outcomes, native nested-sheet cancellation/dismissal/reuse and actual Save Report acceptance pass. Full rendered layout, keyboard/spoken accessibility, exact cleanup failures and live recovery remain unverified. Effort: S.**

- **Problem / benefit:** Transfers can finish before report writing or permission-setting fails. Users need the completed, failed/skipped and unattempted outcomes and a route to their files.
- **Implementation:** `DriveCore/BatchReportPersistence.swift` creates a new private report exclusively and verifies permissions before writing; `BatchDownloads.swift` retains outcomes and primary/cleanup causes on failure. `Stores/BatchDownloadModel.swift` retains the full report and saves an explicit copy without Google calls. `Views/ReportCopyButton.swift` supplies its own results window for the nested save panel; `BatchDownloadView.swift` displays errors, every retained category up to its display cap, the actual confirmed report path and separate report/download Finder actions. Dismissal/failure preserves earlier outcomes/location; only confirmed persistence clears errors. Automatic persistence deliberately survives transfer cancellation.
- **Dependencies / permissions / blockers:** Existing Foundation/filesystem/AppKit only for copy recovery; no new scope or package. Seven report checks use real task-owned destinations and retained model state. Five native component/dialog checks pass without startup/Google/Keychain. Full capture remains unavailable (thumbnail and ScreenCaptureKit failures); exact write/close/secondary cleanup failures and cleanup under concurrent pathname replacement remain unverified. Preserve the retired multi-view crash investigation and prior evidence boundaries in the verification report.
- **Acceptance / validation:** Occupied files/symlinks remain unchanged; 160 outcomes and 135 unattempted paths round-trip with private modes. A missing/denied destination can be retried explicitly at a new path; pre-cancelled/stale/unfinished copies do not write. The final native dialog saves the exact retained JSON while earlier files and cancelled/failed counts remain unchanged. Complete remaining long-error/path layout, keyboard/spoken accessibility and failure-window checks separately; do not describe synthetic transport as live Google recovery.

### P1 — Explain local-only filters before Google search

**Status: verified for compiler/synthetic workflows and native demo guidance/recovery; live Google behavior remains outside this boundary. Effort: S.**

- **Problem / benefit:** The Google-search button previously accepted filters that the query compiler then rejected. Explain the correction before a click while preserving local search.
- **Implementation:** Reuse `DriveCore/Search.swift` query validation in `Stores/AppModel.swift`; `Views/FilterView.swift` displays the reason and disables the unsupported action. Keep size, extension, exact ID, discovery dates and storage scopes local rather than dropping them. Label invalid input separately from an otherwise valid local-only filter.
- **Dependencies / permissions / blockers:** Existing metadata access and compiler; no new scope. Synthetic transport and the demo support independent checks.
- **Acceptance / validation:** Unsupported filters retain their values and issue no request. A supported compound query still follows every page and retains the same filter. Native checks verify the reason appears, clears after correction, and does not interfere with local results or keyboard focus.

## Next independent implementation priorities

### P1 — Resume guided connection at the next actionable step

**Status: partial — startup gating, local resume-step selection, demo routing and synthetic native saved-state/manual navigation pass; full layout, real restoration and live recovery remain unverified. Effort: M.**

- **Problem / benefit:** Returning users reopen a five-step guide at API setup even when a Desktop client or sign-in is already saved. A clear next action reduces repeated setup and confusion.
- **Implementation:** `Views/SetupView.swift` waits for `AppModel.ready` before constructing the stateful guide. It opens API setup without an available client, Sign in with an available client when disconnected or in demo, and Verify synchronization with a saved sign-in outside demo. Later flag changes preserve manual Back/sidebar navigation. Cold demo startup intentionally skips credential restoration; available flags do not certify a real Keychain read. The session-sync verification label and existing missing-client/collection-gap guidance remain explicit. Review consent rejection and live recovery using `Services/OAuth.swift`, `OAuthResponse.swift` and `Stores/AppModel.swift` errors.
- **Dependencies / permissions / blockers:** Existing Keychain/OAuth contracts only. Refresh official Google documentation before altering Cloud setup instructions or their review date. A distributed client or verification cannot be substituted for personal setup without a separate product decision.
- **Acceptance / validation:** Native first-use, imported-client, saved-sign-in and incomplete-sync flags open the appropriate step after readiness; Back/review survives later flag updates. A startup-error flag exits loading and keeps its error visible. Real restoration, consent and API enablement remain separate user/browser checkpoints. Cancellation retains prior sign-in only before replacement, where the contract promises it. Never display tokens or ask for them in chat. The local connection-start cancellation checks in the following item pass; full layout and live recovery remain open for this guide.

### P1 — Give cancellation and recoverable errors accurate next actions

**Status: partial — report/discovery and single-file download/preview recovery pass synthetic transport, real filesystem/model and bounded native panel/component checks. Actual app launch/AX and a native report Save click pass; full visual/keyboard/spoken inspection remains limited. Connection/synchronization retain their recorded boundaries; exact interruption windows and live recovery remain unverified. Effort: S/M.**

- **Problem / benefit:** Cancellation recovery must match the operation and retained data. The generic runner now gives a neutral notice; operation-specific advice remains incomplete.
- **Implementation:** Structured Google diagnostics retain safe reasons and HTTP status without provider-message/query leakage; HTTP 410 guidance distinguishes change tracking from file access and preserves unconfirmed mutation outcomes. The generic runner keeps a neutral notice. `Stores/AppModel.swift`'s synchronization boundary now explains retained committed observations, potentially older displayed results, Refresh continuation and initial-scan restart; it checks cancellation before/after the final success work. Early batch cancellation without a report uses phase-neutral destination guidance instead of assuming discovery failed. `Services/Loopback.swift` now rejects cancelled/terminal/repeated startup, cancels readiness and code waits, and closes pending connections while allowing queued callback responses to finish. `AppModel.connect()` checks cancellation before browser navigation/token exchange and awaits listener cleanup on failures. The sign-in cancellation notice gives retry/synchronization advice without promising rollback: token persistence precedes account-root/workspace validation. Eight real-localhost/model tests and production guide controls pass without Google or Keychain writes; exact creation-to-readiness interruption and live token/browser behavior remain unverified. `Stores/FileActionsModel.swift` now distinguishes save-panel dismissal/cancellation, saved-download cleanup warnings and destination failures. `Services/DownloadSavePanel.swift` cancels only its owned sheet and hides it on completion; native cancel, forced abort, overlapping waits and reuse pass an in-process AppKit harness. `PreviewStore.swift` checks cancellation, validates bounded content and creates exclusive private files; failed persistence cleans its own file and retains primary/cleanup causes. Publication checks a generation for file-selection/account/workspace changes before and after saving, removing only an unpublished result. Earlier previews remain until replacement. Exact during-write and post-save/pre-publication cancellation are not forced by tests. Report recovery now offers an exclusive private copy of retained outcomes with accurate saved-location/cancellation state. Discovery publishes metadata/page/cycle gaps, omits children from failed listings and explains whole-folder retry; final-callback cancellation cannot return a successful plan. The stopped discovery presentation explains no transfers/batch folder and unknown descendant totals. The download interruption/destination priority below now owns the verified local streaming/memory work and its remaining controlled failure windows. Keep exact handoff/native layout/live gaps open. Do not weaken uncertain Trash outcomes.
- **Dependencies / permissions / blockers:** No new scope or dependency. Synthetic requests and real local destinations are sufficient for preparation; live network interruptions remain separate.
- **Acceptance / validation:** Cancelled downloads never claim success; existing destinations remain unchanged. Preview cancellation leaves no retained temporary content. `SyncCancellationTests.swift` verifies both cancellation forms, retained pages/cursors across database reopen, unchanged earlier complete-poll/displayed results, explicit 403 errors and successful Refresh continuation. `ConnectionCancellationTests.swift` verifies pre-cancelled start/code, cancel-before-start, active callback-task cancellation, rejected repeated startup with the first callback still usable, state-checked consent rejection, incomplete local TCP request closure and immediate model cancellation preserving synthetic workspace state. These do not certify real saved-credential preservation. Exact post-reload/notification and listener creation-to-readiness cancellation instants and live interruption remain separate checks. `SingleFileRecoveryTests.swift` and `PreviewRecoveryTests.swift` verify saved bytes/0600, HTTP denial and held-transfer cancellation preserving existing content, immediate cancellation without credential startup, stale selection changed/restored, permission failure/retry, safe 0700/0600 storage and denied cleanup. A real staging cleanup failure passes through the production saved/warning presentation handler; the full URLSession cleanup-failure path remains separate. The native harness confirms continuation completion and sheet removal/reuse, including a forced `.abort` response; it does not reproduce natural display failure or keyboard input. ScreenCaptureKit capture failure blocks actual visual/keyboard/Quick Look and spoken checks. An uncertain Trash request never claims the server did nothing.

### P1 — Finish download interruption and destination validation

**Status: partial — local HTTP, active transfer/hash cancellation, complete batch cancellation with real cleanup failures, saved-warning continuation, destination failures and isolated disk memory correction verified. Exact write/close windows, native presentation and live/external-volume checks remain open. Effort: M.**

- **Problem / benefit:** Interrupted content must never replace earlier output, cancellation must retain truthful reports even if cleanup fails, and large-file chunk loops must bound retained memory as well as individual reads.
- **Implementation:** `DriveCore/Downloads.swift` checks write/search access before discovery and retains typed primary/cleanup causes. `BatchDownloads.swift` revalidates each file's parent before requesting content, and stops on cancellation-plus-cleanup failure with an explicit failed item and later unattempted paths. `Downloads.swift` and `DownloadIntegrity.swift` scope Foundation autoreleased read/write/hash buffers to each MiB chunk; post-read cancellation remains explicit. `StreamingDownloadTests.swift` uses known synthetic metadata/media routing plus real loopback HTTP, production URLSession downloads and task-owned disk. `DiskInterruptionTests.swift` covers filesystem failures, completed staging/commit refusal and dynamic checksum interruption. `DownloadBoundaryTests.swift` observes only an exact caller-owned staging directory and forces late batch destination denial. No transfer framework, new dependency, endpoint or permission change.
- **Dependencies / permissions / blockers:** Local preparation requires no Google/Keychain connection. Live downloads use the existing management grant; external volumes and the exact disposable fixture location need participation/resources. Native full layout and spoken review remain separate. No Trash action is needed.
- **Acceptance / validation:** Exact 128 MiB streamed body/private commit, active single/batch cancellation with prior bytes/report preservation, short-body refusal without retry and genuine premature TCP EOF with exactly four bounded read attempts pass. Missing/non-directory/denied roots, corrected-folder retry, occupied-file/symlink refusal and completed-stage cancellation with denied cleanup preserve bytes/causes. Dynamic hashing consumes over three MiB before cancellation and controlled EOF release. Fresh 64/256 MiB debug CLI workloads verify bytes/modes and reduce observed lifetime RSS from 265/870 MiB to about 11.9 MiB; this is not whole-app/network memory. Existing case/Unicode collision checks remain in the full suite. See [current evidence and limits](docs/VERIFICATION.md#download-interruption-and-destinations).
- **Additional verified boundary:** After three MiB of exact private partial bytes, cancellation and controlled EOF release remove the owned staging directory while preserving earlier output and the source. Late destination denial after preflight retains the first saved file, reports authoritative folder creation/child destination errors and sends no child metadata/media request. Both boundary cases remain in the current passing 144-test full suite. These checks do not establish immediate cancellation inside blocking I/O or live Google recovery.
- **Batch cleanup verified boundary:** Three real-loopback/production-URLSession checks download complete known bodies through the public batch API. Cancellation before commit with inaccessible staging retains one saved, one failed and one unattempted item; adding immutability to the exact owned transport temporary retains both cleanup causes. A committed file with failed transport cleanup remains downloaded with a warning and the next file completes. Exact hashes, private modes, complete automatic JSON reports and request counts pass; every owned fault is explicitly repaired. The internal filesystem-saver dependency preserves the public client's production exclusive save. All 144 tests in seven suites pass locally. No shared temporary-parent permissions are changed.
- **Next independent checkpoint:** Preserve typed cancellation when a file close also fails; the current close-error composition can flatten that cause. Keep active hash read-return, write/close faults and failed report cleanup under concurrent pathname replacement distinct. Recheck native failure presentation/keyboard workflow when capture permits. Do not weaken timeouts/assertions or claim blocking I/O can be interrupted immediately. Then continue accessibility and Activity/history performance priorities below.
- **Remaining live checkpoint:** Identify the actual folder containing the user-prepared Doc/Sheet, duplicate-name and empty-folder fixtures before downloads. Verify exports/duplicate contents/empty directory at a new destination, then controlled live interruption and approved external volumes. No credentials in chat. Do not mark this priority or the overall plan complete or begin comparison research while these checks remain open.

### P2 — Clarify empty results and finish accessibility workflows

**Status: partial — Activity zero-match/date correction and reset pass in the actual demo app; no-record presentation passes native accessibility checks. Full no-record layout and broader/spoken accessibility remain unverified. Effort: M.**

- **Problem / benefit:** A blank Activity table gives little help when filters match nothing. Named controls and keyboard checks exist, but spoken usability is unverified.
- **Implementation:** `Views/ActivityView.swift` distinguishes invalid dates, no loaded source records and filters with no matches, retaining the loaded-record/coverage boundary. Both reset controls reuse `AppModel.resetActivityFilters()` and clear the local row selection only after an explicit action. Review focus order and accessible labels in Setup, Filter, History, Storage and batch results. Reuse stable IDs; verify errors and progress without depending on color or icons alone.
- **Dependencies / permissions / blockers:** Native demo and task-owned observations support independent checks. A listening VoiceOver review is required for spoken-output verification; an AX tree is insufficient.
- **Acceptance / validation:** Keyboard-only navigation, filter correction, category navigation, result review and cancellation work at supported window sizes. Empty states retain inputs until an explicit reset. VoiceOver communicates names, state, progress, errors and next actions; record any missing speech coverage honestly.

### P2 — Measure Activity, observed history and deep hierarchy responsiveness

**Status: partial — file-table bounds measured; these workloads are unmeasured. Effort: M/L.**

- **Problem / benefit:** File paging resolved an observed large-table freeze. Activity loads up to 10,000 records and History renders a cutoff set; neither has equivalent scale evidence.
- **Implementation:** Prepare isolated SQLite workloads for `Views/ActivityView.swift`, `HistoryView.swift`, `DriveCore/Navigation.swift` and database snapshot queries. Measure load/filter/sort/selection/RSS for deep ancestors, missing roots, cycles and large sibling sets. If a problem is reproduced, reuse `Views/FilePagination.swift` or move result preparation off the main actor; do not speculate about a required database migration.
- **Dependencies / permissions / blockers:** Local synthetic observations only, no Google scope. Preserve the existing demo and account databases.
- **Acceptance / validation:** Record workload count/depth, timings, memory and measurement overhead. Stable ordering and exact page coverage; superseded loads cannot publish stale results. Cutoff paths must exclude future ancestor names. Recheck UI interaction after any performance change, rather than reporting source timing as native responsiveness.

### P2 — Export observed history with its evidence boundaries

**Status: planned. Effort: M.**

- **Problem / benefit:** Users can browse retained metadata at a cutoff but cannot export that historical view for review.
- **Implementation:** Reuse the current export and hierarchy contracts to serialize the chosen cutoff, per-item observation timestamps, known/unknown ancestor paths and removed/inaccessible state. Add a native save action in `Views/HistoryView.swift`; keep it separate from current Drive existence or Google action time. Inspect existing export components before choosing the format.
- **Dependencies / permissions / blockers:** Local retained SQLite observations; no extra API permission. No competitor or revision-API feature is implied.
- **Acceptance / validation:** Export agrees with the full filtered cutoff set across paging, renames, moves, missing ancestors and database reopen. Cancellation and save failures are explicit; existing files follow the current reviewed save contract. No claim of continuous historical coverage or historical access.

## External validation gates

### P1 — Validate OAuth recovery, account separation and collection coverage

**Status: blocked for live checks; local implementation is partial. Effort: M/L.**

- **Problem / benefit:** A saved grant and successful user-corpus collection do not establish token lifecycle, tenant coverage or safe account switching.
- **Implementation:** Follow the [guided live checklist](docs/VERIFICATION.md#guided-live-validation-checklist) using existing `Services/OAuth.swift`, Keychain credentials, `DriveCore/Collector.swift`, scope membership and account-cache boundaries. Compare known My Drive/Shared Drive items and bounded Activity records. Prepare exact steps for expiry, deliberate revocation/reconnect and a second controlled account; do not change the clock or reveal tokens.
- **Dependencies / permissions / blockers:** User browser participation, controlled accounts and accessible Shared Drive fixtures. Retain metadata/activity scopes or the already chosen management grant; organization denial is a coverage gap, not authority to broaden access. Repository instructions currently require independent tests without connecting a real Google account.
- **Acceptance / validation:** Reconnect errors are actionable, credentials remain in Keychain, accounts cannot mix caches or pending actions, and unavailable scopes remain labelled incomplete. Compare actors/actions only where Google supplies them. Mark each exercised case separately; do not close this gate with synthetic responses.

### P2 — Observe notification delivery and permission transitions

**Status: partial. Effort: M.**

- **Problem / benefit:** SQLite cooldown/acknowledgement tests and OS request acceptance do not prove a visible notification reached the user.
- **Implementation:** Start with Settings' Google-free test in `Views/SettingsView.swift` and `Services/Notifications.swift`; inspect foreground/background delivery and deny/allow transitions. Then use a controlled folder watch to check cooldown, restart and polling gaps. Document the crash boundary between OS acceptance and database acknowledgement rather than claiming exactly-once delivery.
- **Dependencies / permissions / blockers:** Deliberate macOS notification participation and, for a real watch, a controlled Google fixture. No automatic permission expansion or always-on agent.
- **Acceptance / validation:** Observe actual delivery, recovery after denial and duplicate/cooldown behavior. A denied request must not acknowledge unseen events as delivered. Keep transport acceptance, display and live polling evidence distinct.

### P2 — Finish platform and distribution readiness

**Status: blocked for other hardware and signed distribution; local packaging is partial. Effort: L.**

- **Problem / benefit:** Universal compilation and ad hoc archive checks do not establish Intel/older macOS runtime, Gatekeeper acceptance or an installable distributed release.
- **Implementation:** Run the same scoped workflows on supported older macOS and Intel machines/VMs. Use `script/build.sh`, `verify_bundle.sh` and the existing signing/notarization preparation. Keep native CI and Swift/CSQLite CodeQL on the repository's explicit Xcode 26.6; report the actual local toolchain separately. Inspect extraction diagnostics before claiming language coverage.
- **Dependencies / permissions / blockers:** Suitable runtime environments, Developer ID Application identity and a user-configured notarization profile. Signing submission, releases and deployment need separate authorization; credentials stay local.
- **Acceptance / validation:** Startup, SQLite, setup callback and native navigation work on each recorded environment. Generated and extracted bundles retain architecture, resources, icon, identity and valid signatures. Signed/notarized installation must be observed before describing distribution as ready.

## Review gates and deferred additions

### P3 — Comparison research after the current plan is finished

**Status: blocked by the unfinished plan. Effort: M.**

- **Problem / benefit:** Maintained comparable tools may offer useful ideas, but expanding scope now would obscure existing bugs and validation gaps.
- **Implementation:** After current implementation and validation gates close, review actual maintained repositories/apps, features, source and licenses. Present a concise comparison and prioritized additions with benefit, components, effort, API/permission requirements, licensing and fit. The targeted gdrive-cli reference does not authorize selectable export formats or revision browsing.
- **Dependencies / permissions / blockers:** Completion of the current plan and user review of proposed additions. Research itself needs no new Google grant.
- **Acceptance / validation:** Source links support each feature claim; distinguish observed behavior from inference. Present ideas before implementation. Keep Workspace Events infrastructure, an account switcher, People lookups and encryption exploratory until their own decisions.

Permanent deletion and Empty Trash are **not approved for implementation**. The existing [proposal and safeguards](docs/EMPTY_TRASH.md) remain for review. Never empty the user's actual Trash during development.
