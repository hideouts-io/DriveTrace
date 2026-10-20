import DriveCore

let filePageSize: Int = 500

struct FileResultContext: Equatable {
    let queryGeneration: Int
    let order: FileOrder
    let ascending: Bool
    let usesGoogleResults: Bool
}

/// Bound native table updates while retaining the full filtered/sorted result set for search and export.
func filePageRange(total: Int, page: Int) -> Range<Int> {
    precondition(total >= 0 && page >= 0)
    let lastPage = max(0, (total - 1) / filePageSize)
    let start = min(page, lastPage) * filePageSize
    return start..<(start + min(filePageSize, total - start))
}
