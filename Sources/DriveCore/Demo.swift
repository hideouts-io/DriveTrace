import Foundation

public func seedDemo(_ database: Database) async throws {
    let now = Date()
    var files: [DriveFile] = []
    for (id, name, parent) in [("root", "My Drive", ""), ("design", "Design studio", "root"), ("research", "Research", "root"), ("media", "Media library", "root"), ("archive", "Archive", "research"), ("team", "Team workspace", "")] {
        var folder = DriveFile(id: id, name: name, mimeType: "application/vnd.google-apps.folder")
        folder.parents = parent.isEmpty ? [] : [parent]; folder.trashed = false
        if id == "team" { folder.driveId = "demo-shared" }
        files.append(folder)
    }
    let names = ["Brand exploration.fig", "Launch film.mov", "Quarterly strategy", "Research notes.pdf", "Customer interviews.zip", "Product photography.dng", "Roadmap.xlsx", "Launch checklist", "Prototype walkthrough.mp4", "Design system.sketch", "Market analysis.csv", "Architecture overview.pdf"]
    let mimes = ["application/octet-stream", "video/quicktime", "application/vnd.google-apps.document", "application/pdf", "application/zip", "image/x-adobe-dng", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.google-apps.document", "video/mp4", "application/octet-stream", "text/csv", "application/pdf"]
    let folders = ["design", "media", "research", "archive", "team"]
    for i in 0..<84 {
        let slot = i % names.count
        var file = DriveFile(id: "demo-\(i)", name: i < 12 ? names[slot] : "\(names[slot].components(separatedBy: ".").first!) — v\(i / 12 + 1)\((names[slot] as NSString).pathExtension.isEmpty ? "" : "." + (names[slot] as NSString).pathExtension)", mimeType: mimes[slot])
        file.parents = [folders[i % folders.count]]; file.trashed = i == 83
        file.shared = i % 4 == 0; file.ownedByMe = i % 3 != 0
        file.owners = [Person(displayName: i % 3 == 0 ? "Alex Morgan" : "You", emailAddress: i % 3 == 0 ? "alex@example.test" : "you@example.test", permissionId: "demo-person-\(i % 3)")]
        if !file.mimeType.hasPrefix("application/vnd.google-apps") {
            file.size = String(Int64((i + 1) * (slot == 1 || slot == 8 ? 84_300_000 : 231_000)))
            file.quotaBytesUsed = String((file.bytes ?? 0) * 2)
        }
        if file.parents == ["team"] { file.driveId = "demo-shared" }
        if i % 3 == 0 { file.sharedWithMeTime = timestamp(now.addingTimeInterval(Double(-i * 2600))) }
        file.createdTime = timestamp(now.addingTimeInterval(Double(-i * 5700 - 700)))
        file.modifiedTime = timestamp(now.addingTimeInterval(Double(-i * 1300)))
        file.fileExtension = (file.name as NSString).pathExtension
        if i % 7 == 0 {
            file.permissions = [try JSONDecoder().decode(Permission.self, from: Data("{\"id\":\"anyone\",\"type\":\"anyone\",\"role\":\"reader\",\"allowFileDiscovery\":false}".utf8))]
        }
        files.append(file)
    }
    var shortcut = DriveFile(id: "demo-shortcut", name: "Latest strategy", mimeType: "application/vnd.google-apps.shortcut")
    shortcut.parents = ["design"]; shortcut.shortcutDetails = try JSONDecoder().decode(Shortcut.self, from: Data("{\"targetId\":\"demo-2\",\"targetMimeType\":\"application/vnd.google-apps.document\"}".utf8))
    files.append(shortcut)
    try await database.beginBaseline(stream: "demo")
    try await database.stage(files, stream: "demo")
    try await database.promote(stream: "demo", cursor: "demo-cursor", detected: timestamp(now.addingTimeInterval(-86400)))
    var events: [DriveEvent] = []
    for i in 0..<160 {
        let file = files[6 + i % 84]
        let action = ["UPLOADED", "MODIFIED", "MOVED", "RENAMED", "SHARED", "CREATED", "TRASHED", "RESTORED"][i % 8]
        let time = timestamp(now.addingTimeInterval(Double(-i * 1700)))
        events.append(DriveEvent(id: "demo-event-\(i)", fileID: file.id, name: file.name, action: action, time: time, detected: time, source: .demo, actor: i % 3 == 0 ? "Alex Morgan (demo)" : "You (demo)", parents: file.parents ?? [], previousParents: action == "MOVED" ? ["archive"] : [], previousName: action == "RENAMED" ? "Untitled draft" : nil, raw: "{\"demo\":true,\"action\":\"\(action)\",\"target\":\"\(file.id)\"}"))
    }
    try await database.recordActivity(events, watermark: nil)
    try await database.setSetting("rootID", value: "root")
    try await database.setSetting("demo.seeded", value: "2")
    try await database.setSetting("drives", value: "[{\"id\":\"demo-shared\",\"name\":\"Team workspace\"}]")
}
