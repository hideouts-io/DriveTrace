import SwiftUI
import AppKit
import UserNotifications
import DriveCore

@MainActor @Observable final class AppModel {
    var files: [DriveFile] = []
    var events: [DriveEvent] = []
    var drives: [SharedDrive] = []
    var saved: [SavedSearch] = []
    var watches: [WatchRule] = []
    var facts = FileFacts(firstSeen: [:], lastActivity: [:], activityCounts: [:])
    var selection: String? = "all"
    var selectedFiles: Set<String> = []
    var selectedFile: String? {
        get { selectedFiles.count == 1 ? selectedFiles.first : nil }
        set { selectedFiles = newValue.map { [$0] } ?? [] }
    }
    var batchDownload: BatchDownloadPresentation?
    var filter = FileFilter()
    var storageGrouping = "type"
    var minimumSizeInput = ""
    var maximumSizeInput = ""
    var searching = false
    var focusSearchRequested = false
    var filterValidationError: String? {
        for value in [minimumSizeInput, maximumSizeInput] where !value.isEmpty {
            guard let bytes = Int64(value), bytes >= 0 else { return "Size must be a nonnegative whole number of bytes. Correct the value or clear the search." }
        }
        do { try validateFilter(filter); return nil } catch { return error.localizedDescription }
    }
    var activityValidationError: String? {
        do { try validateDateRange(after: activityAfter, before: activityBefore, label: "Activity range"); return nil } catch { return error.localizedDescription }
    }
    var order: FileOrder = .name
    var ascending = true
    var results: [DriveFile] = []
    var resultGeneration = 0
    var serverResults: [DriveFile]?
    var serverCoverage = ""
    var busy = false
    var progress = ""
    var error: String?
    var gaps: [String] = []
    var isDemo = false
    var connected = false
    var hasClient = false
    var syncVerified = false
    var requestedAccess: DriveAccess = .metadata
    var managementGranted = false
    var pendingTrash: DriveFile?
    var pendingBatchTrash: BatchTrashPresentation?
    var preview: FilePreview?
    let previewStore = PreviewStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("DriveExplorerPreviews", isDirectory: true))
    var operationNotice: String?
    var notificationStatusText = "Checking macOS permission…"
    var notificationTestNotice: String?
    var ready = false
    private var starting = false
    var lastSync: String?
    var rootID = "root"
    var rootMetadata: DriveFile?
    var autoRefresh = UserDefaults.standard.bool(forKey: "autoRefresh") { didSet { UserDefaults.standard.set(autoRefresh, forKey: "autoRefresh") } }
    var notifications = UserDefaults.standard.bool(forKey: "notifications") { didSet { UserDefaults.standard.set(notifications, forKey: "notifications") } }
    var showFilters = false
    var showInspector = true
    var activityActor = ""
    var activityAction = ""
    var activityTarget = ""
    var activityAfter = ""
    var activityBefore = ""
    var database: Database?
    let credentials = Credentials()
    var client: GoogleClient?
    private var operation: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var callback: Loopback?
    private let baseURL: URL
    init() {
        baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DriveExplorer", isDirectory: true)
    }
    var filteredEvents: [DriveEvent] {
        guard activityValidationError == nil else { return [] }
        return events.filter {
            (activityActor.isEmpty || ($0.actor ?? "").localizedCaseInsensitiveContains(activityActor)) &&
            (activityAction.isEmpty || $0.action == activityAction) &&
            (activityTarget.isEmpty || $0.fileID == activityTarget || $0.name.localizedStandardContains(activityTarget)) &&
            within($0.time, after: activityAfter, before: activityBefore)
        }
    }
    var selected: DriveFile? { files.first { $0.id == selectedFile } ?? serverResults?.first { $0.id == selectedFile } }
    private(set) var index: [String: DriveFile] = [:]
    private(set) var folderTrees: [String: [FolderNode]] = [:]
    var navigationRoots: [String: String] {
        var roots = Dictionary(uniqueKeysWithValues: drives.map { ($0.id, $0.name) })
        roots[rootID] = "My Drive"
        return roots
    }
    var title: String {
        if let scope = filter.storage { return storageTitle(scope, index: index, drives: drives) }
        guard let selection else { return "All files" }
        if selection.hasPrefix("folder:") { return index[String(selection.dropFirst(7))]?.name ?? "Folder" }
        if selection.hasPrefix("drive:") { return drives.first { $0.id == String(selection.dropFirst(6)) }?.name ?? "Shared Drive" }
        return ["all":"All files", "my":"My Drive", "shared":"Shared with me", "newest":"Newest items", "largest":"Largest files", "activity":"Activity", "history":"Observed history", "security":"Sharing audit", "storage":"Storage overview", "watches":"Folder watches", "trash":"Trash"][selection] ?? "Drive Explorer"
    }
    func start() async {
        guard !ready && !starting else { return }; starting = true
        defer { ready = true; starting = false }
        do {
            try await previewStore.clear()
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            let demo = UserDefaults.standard.bool(forKey: "demoMode")
            if !demo { try await restoreConnection() }
            client = GoogleClient(tokens: credentials, session: URLSession(configuration: .ephemeral))
            try await openDatabase(demo: demo)
            if autoRefresh && connected { setPolling(true) }
        } catch { self.error = error.localizedDescription }
    }
    private func restoreConnection() async throws {
        connected = try await credentials.restore()
        managementGranted = await credentials.grantedScopes().contains("https://www.googleapis.com/auth/drive")
        hasClient = await credentials.hasConfiguration()
    }
    private func openDatabase(demo: Bool) async throws {
        if let database { try await database.close() }
        let directory = baseURL.appendingPathComponent(demo ? "Demo" : "Account-" + (UserDefaults.standard.string(forKey: "accountCache") ?? "unconnected"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try Database(path: directory.appendingPathComponent("drive.sqlite").path)
        database = store; isDemo = demo; syncVerified = false; serverResults = nil; selectedFile = nil
        if demo, try await store.setting("demo.seeded") != "2" { try await store.clearCache(); try await seedDemo(store) }
        UserDefaults.standard.set(demo, forKey: "demoMode")
        try await reload()
    }
    func toggleDemo() {
        guard !busy else { return }
        run {
            try await self.openDatabase(demo: !self.isDemo)
            if !self.isDemo { try await self.restoreConnection() }
        }
    }
    func reload() async throws {
        guard let database else { throw MonitorError.database("The local database has not opened.") }
        let loaded = try await database.files()
        var loadedFacts = try await database.facts()
        let root = try await decodeSetting("rootMetadata", type: DriveFile.self)
        let rootID = try await database.setting("rootID") ?? "root"
        let drives = try await decodeSetting("drives", type: [SharedDrive].self) ?? []
        let preparation = Task.detached(priority: .userInitiated) {
            try prepareNavigation(files: loaded, root: root, roots: [rootID] + drives.map(\.id))
        }
        let navigation = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
        try Task.checkCancellation()
        loadedFacts.locations = navigation.locations
        files = loaded; facts = loadedFacts; index = navigation.index; folderTrees = navigation.roots
        rootMetadata = root; self.rootID = rootID; self.drives = drives
        events = try await database.events(fileID: nil, limit: 10000)
        lastSync = try await database.setting("lastSync")
        gaps = try await decodeSetting("coverage.gaps", type: [String].self) ?? []
        saved = try await decodeSetting("saved", type: [SavedSearch].self) ?? []
        watches = try await decodeSetting("watches", type: [WatchRule].self) ?? []
        updateResults()
    }
    private func decodeSetting<T: Decodable & Sendable>(_ key: String, type: T.Type) async throws -> T? {
        guard let text = try await database?.setting(key) else { return nil }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
    func navigate(_ value: String?) {
        minimumSizeInput = ""; maximumSizeInput = ""
        selection = value; serverResults = nil; selectedFile = nil; filter = FileFilter()
        if value == "largest" { order = .size; ascending = false }
        else if value == "newest" { order = .created; ascending = false }
        else { order = .name; ascending = true }
        updateResults()
    }
    func resetSearch() {
        minimumSizeInput = ""; maximumSizeInput = ""; filter = FileFilter(); serverResults = nil; updateResults()
    }
    func openStorageGroup(_ group: StorageGroup) {
        navigate("all")
        filter.storage = group.scope
        order = .size; ascending = false
        updateResults()
    }
    func updateSizes() {
        filter.minimumBytes = Int64(minimumSizeInput); filter.maximumBytes = Int64(maximumSizeInput)
        serverResults = nil; updateResults()
    }
    func updateResults() {
        searchTask?.cancel()
        if filterValidationError != nil { results = []; resultGeneration += 1; searching = false; return }
        searching = true
        let remote = serverResults != nil
        let all = serverResults ?? files, filter = filter, order = order, ascending = ascending, facts = facts, scope = selection, root = rootID
        searchTask = Task {
            let task = Task.detached(priority: .userInitiated) { () throws -> [DriveFile] in
                try Task.checkCancellation()
                let scoped = try all.filter { file in
                    try Task.checkCancellation()
                    if remote { return true }
                    if selfScopeFolder(scope) != nil { return (file.parents ?? []).contains(selfScopeFolder(scope)!) }
                    if let scope, scope.hasPrefix("drive:") { return file.driveId == String(scope.dropFirst(6)) }
                    if scope == "my" { return (file.parents ?? []).contains(root) }
                    if scope == "shared" { return file.sharedWithMeTime != nil }
                    if scope == "trash" { return file.trashed == true }
                    if scope == "security" { return file.shared == true || !(file.permissions ?? []).isEmpty }
                    return file.id != root && (scope != "largest" || !file.isFolder)
                }
                var effective = filter
                if scope == "trash" { effective.trash = "trash" }
                let matching = try scoped.filter { file in
                    try Task.checkCancellation()
                    return remote || (matches(file, filter: effective) && within(facts.firstSeen[file.id], after: effective.discoveredAfter, before: effective.discoveredBefore))
                }
                return try orderedFiles(matching, order: order, ascending: ascending, facts: facts)
            }
            do {
                let output = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled else { return }; results = output; resultGeneration += 1; searching = false
            } catch is CancellationError {
                // A newer search owns the spinner and result set.
            } catch {
                guard !Task.isCancelled else { return }; self.error = error.localizedDescription; searching = false; results = []
            }
        }
    }
    func run(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil; operationNotice = nil
        operation = Task {
            defer { busy = false; progress = ""; operation = nil }
            do { try await body() }
            catch is CancellationError { operationNotice = "Operation cancelled. Any committed observations are retained; refresh to continue synchronization." }
            catch let failure as URLError where failure.code == .cancelled { operationNotice = "Operation cancelled. Refresh to continue synchronization." }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel(); if let callback { Task { await callback.cancel() } } }
    func sync() {
        guard !isDemo else { updateResults(); return }
        run {
            self.syncVerified = false
            guard let client = self.client else { throw MonitorError.invalid("App is not ready.") }
            let root = try await client.file(id: "root")
            let accountKey = digest(root.id)
            if UserDefaults.standard.string(forKey: "accountCache") != accountKey {
                UserDefaults.standard.set(accountKey, forKey: "accountCache")
                try await self.openDatabase(demo: false)
            }
            guard let database = self.database else { throw MonitorError.database("Account database did not open.") }
            self.connected = true
            let before = Set(self.events.map(\.id))
            try await database.setSetting("rootID", value: root.id)
            try await database.setSetting("rootMetadata", value: encoded(root))
            let result = try await synchronize(client: client, database: database) { status in
                await MainActor.run { self.progress = "\(status.message) · \(status.count) records" }
            }
            self.gaps = result.gaps
            try await database.setSetting("coverage.gaps", value: encoded(result.gaps))
            if result.gaps.isEmpty { try await database.setSetting("lastSync", value: timestamp(Date())) }
            try await self.reload()
            self.syncVerified = result.gaps.isEmpty
            try await self.notify(events: self.events.filter { !before.contains($0.id) })
        }
    }
    func queryGoogle() {
        run {
            guard !self.isDemo, let client = self.client else { throw MonitorError.invalid("Google search requires a connected account. Use Local index in demo mode.") }
            if let failure = self.filterValidationError { throw MonitorError.invalid(failure) }
            let query = try serverQuery(self.filter)
            var output: [DriveFile] = []; var page: String?; var seen: Set<String> = []
            repeat {
                try Task.checkCancellation()
                let response = try await client.files(query: query, drive: self.filter.drive.isEmpty ? nil : self.filter.drive, page: page)
                guard response.incompleteSearch != true else { throw MonitorError.invalid("Google reported an incomplete search. Narrow the scope to a Shared Drive.") }
                output += response.files ?? []; page = response.nextPageToken
                if let page, !seen.insert(page).inserted { throw MonitorError.invalid("Search pagination repeated a cursor.") }
                self.progress = "Google search · \(output.count) records"
            } while page != nil
            self.serverResults = output; self.serverCoverage = "Google query · all returned pages · \(output.count) results"
            self.updateResults()
        }
    }
    func saveSearch(name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let failure = filterValidationError { error = failure; return }
        let item = SavedSearch(id: UUID().uuidString, name: name, filter: filter)
        run { let searches = self.saved + [item]; try await self.database?.setSetting("saved", value: encoded(searches)); self.saved = searches }
    }
    func loadSearch(_ search: SavedSearch) { minimumSizeInput = search.filter.minimumBytes.map(String.init) ?? ""; maximumSizeInput = search.filter.maximumBytes.map(String.init) ?? ""; selection = "all"; serverResults = nil; filter = search.filter; showFilters = true; updateResults() }
    func removeSearch(_ id: String) { run { let searches = self.saved.filter { $0.id != id }; try await self.database?.setSetting("saved", value: encoded(searches)); self.saved = searches } }
    func watch(_ folder: DriveFile) {
        run {
            let rules = self.watches.filter { $0.id != folder.id } + [WatchRule(id: folder.id, name: folder.name, actions: [], enabled: true, cooldown: 300)]
            try await self.database?.setSetting("watches", value: encoded(rules)); self.watches = rules
        }
    }
    func saveWatches(_ rules: [WatchRule]) { run { try await self.database?.setSetting("watches", value: encoded(rules)); self.watches = rules } }
    func setPolling(_ enabled: Bool) {
        autoRefresh = enabled; pollTask?.cancel(); pollTask = nil
        if enabled { pollTask = Task { while !Task.isCancelled { do { try await Task.sleep(for: .seconds(60)); if !self.busy && self.pendingTrash == nil && self.pendingBatchTrash == nil && self.selectedFiles.isEmpty && self.batchDownload == nil && !self.isDemo && self.connected { self.sync() } } catch is CancellationError { break } catch { self.error = error.localizedDescription; break } } } }
    }
    func requestNotifications() {
        run {
            self.notifications = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            self.notificationStatusText = notificationStatus(settings)
            try requireNotificationAuthorization(settings.authorizationStatus)
        }
    }
    func refreshNotificationStatus() async {
        notificationStatusText = notificationStatus(await UNUserNotificationCenter.current().notificationSettings())
    }
    func testNotification() {
        run {
            self.notificationTestNotice = nil
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            self.notificationStatusText = notificationStatus(settings)
            try requireNotificationAuthorization(settings.authorizationStatus)
            let content = UNMutableNotificationContent()
            content.title = "Drive Explorer notification test"
            content.body = "This is a local test. No Google account or Drive data was used."
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: "drive-explorer-local-test", content: content, trigger: nil))
            self.notificationTestNotice = "macOS accepted the test request. Check for a banner or Notification Center entry; acceptance does not prove display. Focus and system notification settings can suppress alerts."
        }
    }
    private func notify(events: [DriveEvent]) async throws {
        guard notifications, !isDemo else { return }
        guard let database else { throw MonitorError.database("Cannot deliver watch notifications without an open database.") }
        var deliveries: [(rule: WatchRule, batch: WatchBatch)] = []
        for rule in watches where rule.enabled {
            let pendingKey = "pendingNotifications." + rule.id
            let existing = try await decodeSetting(pendingKey, type: [String].self) ?? []
            let last = try await database.setting("notified." + rule.id)
            let batch = try watchBatch(rule: rule, files: files, events: events, pending: existing, lastSent: last, now: Date())
            guard !batch.recordIDs.isEmpty else { continue }
            try await database.setSetting(pendingKey, value: encoded(batch.recordIDs))
            guard batch.deliveryDue else { continue }
            deliveries.append((rule: rule, batch: batch))
        }
        for (rule, batch) in deliveries {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            notificationStatusText = notificationStatus(settings)
            try requireNotificationAuthorization(settings.authorizationStatus)
            let content = UNMutableNotificationContent(); content.title = "\(rule.name) · \(batch.recordIDs.count) new records"; content.body = "Open Drive Explorer to review the recorded activity."; content.sound = .default
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            try await database.acknowledgeWatch(ruleID: rule.id, delivered: batch.recordIDs, sentAt: timestamp(Date()))
        }
    }

    func importClient() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard let window = NSApp.keyWindow else { error = "Open the connection guide before importing a client."; return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.run {
                try await self.credentials.configure(Data(contentsOf: url))
                self.hasClient = await self.credentials.hasConfiguration()
                self.connected = try await self.credentials.restore(); self.managementGranted = await self.credentials.grantedScopes().contains("https://www.googleapis.com/auth/drive"); self.syncVerified = false
                self.operationNotice = "Desktop client saved in Keychain. Continue with browser sign-in."
            }
        }
    }

    func connect() {
        let access = requestedAccess
        run {
            let state = try randomURLToken(), verifier = try randomURLToken()
            let receiver = Loopback(state: state); self.callback = receiver
            defer { self.callback = nil }
            let clientID = try await self.credentials.clientID()
            let redirect = try await receiver.start()
            guard NSWorkspace.shared.open(authorizationURL(clientID: clientID, redirect: redirect, state: state, verifier: verifier, access: access)) else { await receiver.cancel(); throw MonitorError.authentication("Could not open your default browser.") }
            self.progress = "Complete Google sign-in in your browser"
            let code = try await receiver.code()
            try await self.credentials.exchange(code: code, verifier: verifier, redirect: redirect, access: access)
            guard let client = self.client else { throw MonitorError.invalid("Google client is unavailable.") }
            let root = try await client.file(id: "root")
            UserDefaults.standard.set(digest(root.id), forKey: "accountCache")
            self.connected = true
            self.managementGranted = await self.credentials.grantedScopes().contains("https://www.googleapis.com/auth/drive")
            try await self.openDatabase(demo: false)
            try await self.database?.setSetting("rootID", value: root.id)
            self.rootID = root.id
            self.operationNotice = "Sign-in succeeded. Run the first synchronization to check metadata and activity access."
        }
    }
    func disconnect() { setPolling(false); run { try await self.credentials.disconnect(); self.connected = false; self.managementGranted = false; self.syncVerified = false } }
    func clearCache() { run { try await self.database?.clearCache(); if self.isDemo, let database = self.database { try await seedDemo(database) }; self.gaps = []; try await self.reload() } }
    func clearHistory() { run { try await self.database?.clearHistory(); try await self.reload() } }
    func export(_ format: ExportFormat) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "drive-\(selection == "activity" ? "activity" : "files").\(format.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { let data = try self.selection == "activity" ? exportEvents(self.filteredEvents, format: format) : exportFiles(self.results, format: format); try data.write(to: url, options: .atomic) }
    }
    func open(_ file: DriveFile) {
        if isDemo { error = "Demo files are synthetic and cannot be opened in Google Drive."; return }
        if let link = file.webViewLink {
            guard let url = URL(string: link), url.scheme == "https", ["drive.google.com", "docs.google.com"].contains(url.host ?? "") else { error = "Google returned an unsupported web link. Inspect the file metadata before opening it."; return }
            guard NSWorkspace.shared.open(url) else { error = "macOS could not open the Google Drive URL."; return }
            return
        }
        let id = file.shortcutDetails?.targetId ?? file.id
        guard let url = URL(string: "https://drive.google.com/\(file.isFolder ? "drive/folders" : "file/d")/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")") else { error = "Cannot construct the Google Drive URL."; return }
        guard NSWorkspace.shared.open(url) else { error = "macOS could not open the Google Drive URL."; return }
    }
}
private func selfScopeFolder(_ scope: String?) -> String? { guard let scope, scope.hasPrefix("folder:") else { return nil }; return String(scope.dropFirst(7)) }
