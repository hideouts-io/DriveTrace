/// Bound native table updates while retaining the full filtered/sorted result set for search and export.
func filePageRange(total: Int, page: Int) -> Range<Int> {
    precondition(total >= 0 && page >= 0)
    let pageSize = 500
    let lastPage = max(0, (total - 1) / pageSize)
    let start = min(page, lastPage) * pageSize
    return start..<(start + min(pageSize, total - start))
}
