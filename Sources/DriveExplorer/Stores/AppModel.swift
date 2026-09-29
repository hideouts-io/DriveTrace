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
    var selectedFile: String?
    var filter = FileFilter()
    var filterValidationError: String?
    var order: FileOrder = .name
    var ascending = true
    var results: [DriveFile] = []
    var serverResults: [DriveFile]?
    var serverCoverage = ""
    var busy = false
    var progress = ""
    var error: String?
    var gaps: [String] = []
    var isDemo = false
    var connected = false
    var ready = false
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
    private var client: GoogleClient?
    private var operation: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var callback: Loopback?
    private let baseURL: URL
    init() {
        baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DriveExplorer", isDirectory: true)
    }
    var filteredEvents: [DriveEvent] {
        events.filter {
            (activityActor.isEmpty || ($0.actor ?? "").localizedCaseInsensitiveContains(activityActor)) &&
            (activityAction.isEmpty || $0.action == activityAction) &&
            (activityTarget.isEmpty || $0.fileID == activityTarget || $0.name.localizedStandardContains(activityTarget)) &&
            within($0.time, after: activityAfter, before: activityBefore)
        }
    }
    var selected: DriveFile? { files.first { $0.id == selectedFile } ?? serverResults?.first { $0.id == selectedFile } }
    var index: [String: DriveFile] {
        var values = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        if var rootMetadata { rootMetadata.parents = []; values[rootMetadata.id] = rootMetadata }
        return values
    }
    var title: String {
        guard let selection else { return "All files" }
        if selection.hasPrefix("folder:") { return index[String(selection.dropFirst(7))]?.name ?? "Folder" }
        if selection.hasPrefix("drive:") { return drives.first { $0.id == String(selection.dropFirst(6)) }?.name ?? "Shared Drive" }
        return ["all":"All files", "my":"My Drive", "shared":"Shared with me", "newest":"Newest items", "largest":"Largest files", "activity":"Activity", "security":"Sharing audit", "storage":"Storage overview", "watches":"Folder watches", "trash":"Trash"][selection] ?? "Drive Explorer"
    }
    func start() async {
        guard !ready else { return }; ready = true
        do {
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            connected = try await credentials.restore()
            client = GoogleClient(tokens: credentials, session: .shared)
            try await openDatabase(demo: UserDefaults.standard.bool(forKey: "demoMode"))
            if autoRefresh && connected { setPolling(true) }
        } catch { self.error = error.localizedDescription }
    }
    private func openDatabase(demo: Bool) async throws {
        if let database { try await database.close() }
        let directory = baseURL.appendingPathComponent(demo ? "Demo" : "Account-" + (UserDefaults.standard.string(forKey: "accountCache") ?? "unconnected"), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try Database(path: directory.appendingPathComponent("drive.sqlite").path)
        database = store; isDemo = demo; serverResults = nil; selectedFile = nil
        if demo, try await store.setting("demo.seeded") != "2" { try await store.clearCache(); try await seedDemo(store) }
        UserDefaults.standard.set(demo, forKey: "demoMode")
        try await reload()
    }
    func toggleDemo() {
        guard !busy else { return }
        run { try await self.openDatabase(demo: !self.isDemo) }
    }
    func reload() async throws {
        guard let database else { throw MonitorError.database("The local database has not opened.") }
        files = try await database.files(); events = try await database.events(fileID: nil, limit: 10000); facts = try await database.facts()
        rootMetadata = try await decodeSetting("rootMetadata", type: DriveFile.self)
        let fullIndex = index
        facts.locations = Dictionary(uniqueKeysWithValues: files.map { ($0.id, filePath($0.id, index: fullIndex, visited: [])) })
        rootID = try await database.setting("rootID") ?? "root"
        lastSync = try await database.setting("lastSync")
        gaps = try await decodeSetting("coverage.gaps", type: [String].self) ?? []
        drives = try await decodeSetting("drives", type: [SharedDrive].self) ?? []
        saved = try await decodeSetting("saved", type: [SavedSearch].self) ?? []
        watches = try await decodeSetting("watches", type: [WatchRule].self) ?? []
        updateResults()
    }
    private func decodeSetting<T: Decodable & Sendable>(_ key: String, type: T.Type) async throws -> T? {
        guard let text = try await database?.setting(key) else { return nil }
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
    func navigate(_ value: String?) {
        filterValidationError = nil
        selection = value; serverResults = nil; selectedFile = nil; filter = FileFilter()
        if value == "largest" { order = .size; ascending = false }
        else if value == "newest" { order = .created; ascending = false }
        else { order = .name; ascending = true }
        updateResults()
    }
    func updateResults() {
        searchTask?.cancel()
        if filterValidationError != nil { results = []; return }
        let remote = serverResults != nil
        let all = serverResults ?? files, filter = filter, order = order, ascending = ascending, facts = facts, scope = selection, root = rootID
        searchTask = Task {
            let task = Task.detached(priority: .userInitiated) { () -> [DriveFile] in
                let scoped = all.filter { file in
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
                return orderedFiles(scoped.filter { remote || (matches($0, filter: effective) && within(facts.firstSeen[$0.id], after: effective.discoveredAfter, before: effective.discoveredBefore)) }, order: order, ascending: ascending, facts: facts)
            }
            let output = await task.value
            guard !Task.isCancelled else { return }; results = output
        }
    }
    func run(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; error = nil
        operation = Task {
            defer { busy = false; progress = ""; operation = nil }
            do { try await body() }
            catch is CancellationError { progress = "Cancelled" }
            catch let failure as URLError where failure.code == .cancelled { progress = "Cancelled" }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { operation?.cancel(); if let callback { Task { await callback.cancel() } } }
    func sync() {
        guard !isDemo else { updateResults(); return }
        run {
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
            try await self.notify(events: self.events.filter { !before.contains($0.id) })
        }
    }
    func queryGoogle() {
        run {
            guard !self.isDemo, let client = self.client else { throw MonitorError.invalid("Google search requires a connected account. Use Local index in demo mode.") }
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
        let item = SavedSearch(id: UUID().uuidString, name: name, filter: filter)
        run { let searches = self.saved + [item]; try await self.database?.setSetting("saved", value: encoded(searches)); self.saved = searches }
    }
    func loadSearch(_ search: SavedSearch) { selection = "all"; serverResults = nil; filter = search.filter; showFilters = true; updateResults() }
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
        if enabled { pollTask = Task { while !Task.isCancelled { do { try await Task.sleep(for: .seconds(60)); if !self.busy && !self.isDemo && self.connected { self.sync() } } catch is CancellationError { break } catch { self.error = error.localizedDescription; break } } } }
    }
    func requestNotifications() {
        run { self.notifications = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]); if !self.notifications { throw MonitorError.invalid("Notifications are disabled. Enable Drive Explorer in macOS System Settings → Notifications.") } }
    }
    private func notify(events: [DriveEvent]) async throws {
        guard notifications, !isDemo else { return }
        for rule in watches where rule.enabled {
            let ids = descendants(rule.id, files: files)
            let relevant = events.filter { event in (ids.contains(event.fileID) || !ids.isDisjoint(with: event.parents + event.previousParents)) && (rule.actions.isEmpty || rule.actions.contains(event.action)) }
            let pendingKey = "pendingNotifications." + rule.id
            let existing = try await decodeSetting(pendingKey, type: [String].self) ?? []
            let pending = Set(existing).union(relevant.map(\.id))
            guard !pending.isEmpty else { continue }
            try await database?.setSetting(pendingKey, value: encoded(pending.sorted()))
            let last = try await database?.setting("notified.\(rule.id)")
            if let date = parseDate(last), Date().timeIntervalSince(date) < Double(rule.cooldown) { continue }
            let content = UNMutableNotificationContent(); content.title = "\(rule.name) · \(pending.count) new records"; content.body = "Open Drive Explorer to review the recorded activity."; content.sound = .default
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            try await database?.setSetting("notified.\(rule.id)", value: timestamp(Date()))
            try await database?.setSetting(pendingKey, value: "[]")
        }
    }
    func importClient() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try await self.credentials.configure(Data(contentsOf: url)); self.connected = try await self.credentials.restore(); self.progress = "OAuth client saved in Keychain" }
    }
    func connect() {
        run {
            let state = try randomURLToken(), verifier = try randomURLToken()
            let receiver = Loopback(state: state); self.callback = receiver
            defer { self.callback = nil }
            let clientID = try await self.credentials.clientID()
            let redirect = try await receiver.start()
            guard NSWorkspace.shared.open(authorizationURL(clientID: clientID, redirect: redirect, state: state, verifier: verifier)) else { await receiver.cancel(); throw MonitorError.authentication("Could not open your default browser.") }
            self.progress = "Complete Google sign-in in your browser"
            let code = try await receiver.code()
            try await self.credentials.exchange(code: code, verifier: verifier, redirect: redirect)
            guard let client = self.client else { throw MonitorError.invalid("Google client is unavailable.") }
            let root = try await client.file(id: "root")
            UserDefaults.standard.set(digest(root.id), forKey: "accountCache")
            self.connected = true
            try await self.openDatabase(demo: false)
            try await self.database?.setSetting("rootID", value: root.id)
            self.rootID = root.id
        }
    }
    func disconnect() { setPolling(false); run { try await self.credentials.disconnect(); self.connected = false } }
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
