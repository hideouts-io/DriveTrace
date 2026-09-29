import Foundation
import CryptoKit

public func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

public func transitions(previous: DriveFile?, change: Change, detected: String) throws -> [DriveEvent] {
    guard change.changeType == "file" else { return [] }
    guard let id = change.fileId else { throw MonitorError.invalid("File change lacks fileId; cursor not advanced.") }
    let current = change.file
    let file = current ?? previous
    var actions: [String] = []
    if change.removed == true { actions = ["INACCESSIBLE"] }
    else if let current {
        if let previous {
            if current.name != previous.name { actions.append("RENAMED") }
            if let before = previous.parents, let after = current.parents, Set(before) != Set(after) { actions.append("MOVED") }
            if let before = previous.trashed, let after = current.trashed, before != after { actions.append(after ? "TRASHED" : "RESTORED") }
            if let modified = current.modifiedTime, modified != previous.modifiedTime { actions.append("MODIFIED") }
            if let before = previous.shared, let after = current.shared, before != after { actions.append("PERMISSION") }
            if let before = previous.permissions, let after = current.permissions, Set(before) != Set(after), !actions.contains("PERMISSION") { actions.append("PERMISSION") }
            let before = Set(previous.owners?.compactMap(\.permissionId) ?? [])
            let after = Set(current.owners?.compactMap(\.permissionId) ?? [])
            if !before.isEmpty && !after.isEmpty && before != after { actions.append("OWNERSHIP") }
            if actions.isEmpty && previous != current { actions.append("METADATA") }
        } else { actions = ["DISCOVERED"] }
    } else { throw MonitorError.invalid("Nonremoved change \(id) lacks metadata; cursor not advanced.") }
    let raw = try encoded(change)
    return actions.map { action in
        DriveEvent(id: digest(raw + action), fileID: id, name: file?.name ?? id, action: action,
                   time: change.time, detected: detected, source: .changes, actor: nil,
                   parents: current?.parents ?? [], previousParents: previous?.parents ?? [],
                   previousName: previous?.name, raw: raw)
    }
}

public func normalizeActivity(_ activity: JSONValue, detected: String) throws -> [DriveEvent] {
    guard !activity["actions"].array.isEmpty else { throw MonitorError.invalid("Activity response lacks actions; checkpoint not advanced.") }
    return try activity["actions"].array.compactMap { action in
        let target = action["target"]
        let item = target["driveItem"].object.isEmpty ? target["fileComment"]["parent"].object.isEmpty ? target["drive"] : target["fileComment"]["parent"] : target["driveItem"]
        let targetIdentity = try encoded(target)
        let resource = item["name"].string ?? "unresolved:" + digest(targetIdentity)
        guard let time = action["timestamp"].string ?? action["timeRange"]["endTime"].string ?? activity["timestamp"].string ?? activity["timeRange"]["endTime"].string else {
            throw MonitorError.invalid("Activity action lacks a timestamp or range; checkpoint not advanced.")
        }
        let detail = action["detail"]
        let kind = detail.object.keys.sorted().first ?? "unknown"
        var label = ["create":"CREATED", "edit":"MODIFIED", "rename":"RENAMED", "move":"MOVED", "delete":"DELETED", "restore":"RESTORED", "permissionChange":"PERMISSION", "comment":"COMMENTED"][kind] ?? "UNKNOWN"
        if kind == "create" && detail[kind].object["upload"] != nil { label = "UPLOADED" }
        if kind == "delete" && detail[kind]["type"].string == "TRASH" { label = "TRASHED" }
        if kind == "permissionChange" {
            let added = detail[kind]["addedPermissions"].array
            let removed = detail[kind]["removedPermissions"].array
            if (added + removed).contains(where: { $0["role"].string == "OWNER" }) { label = "OWNERSHIP" }
            else if added.contains(where: { $0.object["anyone"] != nil || $0.object["domain"] != nil }) { label = "SHARED" }
            else if removed.contains(where: { $0.object["anyone"] != nil || $0.object["domain"] != nil }) { label = "UNSHARED" }
        }
        let known = action["actor"]["user"]["knownUser"]
        let actor = known["isCurrentUser"].boolean == true ? "Me" : known["personName"].string
        let parents = detail["move"]["addedParents"].array.compactMap { $0["driveItem"]["name"].string?.replacingOccurrences(of: "items/", with: "") }
        let previous = detail["move"]["removedParents"].array.compactMap { $0["driveItem"]["name"].string?.replacingOccurrences(of: "items/", with: "") }
        guard parseDate(time) != nil else { throw MonitorError.invalid("Activity returned an invalid RFC3339 time; checkpoint not advanced.") }
        let raw = try encoded(activity)
        let identity = try encoded(action)
        return DriveEvent(id: digest(identity + time), fileID: String(resource.dropFirst(resource.hasPrefix("items/") ? 6 : 0)), name: item["title"].string ?? resource, action: label, time: time, detected: detected, source: .activity, actor: actor, parents: parents, previousParents: previous, previousName: detail["rename"]["oldTitle"].string, raw: raw)
    }
}

public func filePath(_ id: String, index: [String: DriveFile], visited: Set<String>) -> String {
    if visited.contains(id) { return "[cycle: \(id)]" }
    guard let file = index[id] else { return "[unresolved: \(id)]" }
    guard let parents = file.parents else { return "[parent unavailable]/" + file.name }
    guard let parent = parents.first else { return file.name }
    return filePath(parent, index: index, visited: visited.union([id])) + "/" + file.name
}

public func descendants(_ folder: String, files: [DriveFile]) -> Set<String> {
    let children = Dictionary(grouping: files.flatMap { file in (file.parents ?? []).map { ($0, file.id) } }, by: { $0.0 })
    var result: Set<String> = []; var pending = [folder]
    while let id = pending.popLast() {
        if result.insert(id).inserted { pending.append(contentsOf: children[id, default: []].map(\.1)) }
    }
    return result
}
