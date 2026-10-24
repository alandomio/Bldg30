import Foundation
import Darwin

public struct DiskUsageEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let bytes: UInt64
    public let isDirectory: Bool
    public let partial: Bool
    public init(url: URL, bytes: UInt64, isDirectory: Bool, partial: Bool = false) {
        self.url = url; self.bytes = bytes; self.isDirectory = isDirectory; self.partial = partial
    }
}

public struct DiskUsageResult: Sendable {
    public let root: URL
    public let entries: [DiskUsageEntry]
    public let largestFiles: [DiskUsageEntry]
    public let visitedCount: Int
    public let inaccessibleCount: Int
    public let excludedCount: Int
    public let limited: Bool
    public init(root: URL, entries: [DiskUsageEntry], largestFiles: [DiskUsageEntry], visitedCount: Int, inaccessibleCount: Int, excludedCount: Int, limited: Bool) {
        self.root = root; self.entries = entries; self.largestFiles = largestFiles; self.visitedCount = visitedCount
        self.inaccessibleCount = inaccessibleCount; self.excludedCount = excludedCount; self.limited = limited
    }
    public var bytes: UInt64 { entries.reduce(0) { sum, entry in let added = sum.addingReportingOverflow(entry.bytes); return added.overflow ? .max : added.partialValue } }
}

public enum DiskUsageScanner {
    public static var defaultRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let data = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        var homeInfo = stat(), dataInfo = stat()
        if lstat(home.path, &homeInfo) == 0, lstat(data.path, &dataInfo) == 0, homeInfo.st_dev == dataInfo.st_dev { return data }
        return (try? home.resourceValues(forKeys: [.volumeURLKey]).volume) ?? home
    }

    /// Read-only allocated-size estimate. Links and other volumes are not traversed.
    public static func scan(_ folder: URL, maximumEntries: Int = 300_000, maximumSeconds: Double = 30) async throws -> DiskUsageResult {
        try Task.checkCancellation()
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        var rootInfo = stat()
        guard root.isFileURL, lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw DeckError.rpc("La cartella non è disponibile o non è leggibile.")
        }
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        struct Identity: Hashable { let device: dev_t; let inode: ino_t }
        var seen = Set<Identity>(), largest: [DiskUsageEntry] = []
        var visited = 0, inaccessible = 0, excluded = 0, limited = false
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, maximumSeconds)
        struct Work { let url: URL; let owner: Int }
        var queue = children.enumerated().map { Work(url: $0.element, owner: $0.offset) }
        var sizes = [UInt64](repeating: 0, count: children.count)
        var partial = [Bool](repeating: false, count: children.count)
        var directories = children.map(\.hasDirectoryPath)
        var cursor = 0
        // Breadth first: one large subtree must not hide every other top-level folder.
        while cursor < queue.count {
            try Task.checkCancellation()
            guard visited < max(0, maximumEntries), ProcessInfo.processInfo.systemUptime < deadline else { limited = true; break }
            let work = queue[cursor]; cursor += 1
            visited += 1
            var info = stat()
            guard lstat(work.url.path, &info) == 0 else { inaccessible += 1; partial[work.owner] = true; continue }
            let type = info.st_mode & mode_t(S_IFMT)
            if work.url == children[work.owner] { directories[work.owner] = type == mode_t(S_IFDIR) }
            guard info.st_dev == rootInfo.st_dev, type != mode_t(S_IFLNK) else { excluded += 1; continue }
            guard seen.insert(Identity(device: info.st_dev, inode: info.st_ino)).inserted else { continue }
            guard type == mode_t(S_IFDIR) || type == mode_t(S_IFREG) else { excluded += 1; continue }
            let bytes = UInt64(max(0, info.st_blocks)) * 512
            let added = sizes[work.owner].addingReportingOverflow(bytes)
            sizes[work.owner] = added.overflow ? .max : added.partialValue
            if type == mode_t(S_IFREG) {
                largest.append(DiskUsageEntry(url: work.url, bytes: bytes, isDirectory: false))
                if largest.count > 40 { largest.sort { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }; largest.removeLast(largest.count - 20) }
                continue
            }
            do {
                let items = try FileManager.default.contentsOfDirectory(at: work.url, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                queue.append(contentsOf: items.map { Work(url: $0, owner: work.owner) })
            } catch { inaccessible += 1; partial[work.owner] = true }
        }
        if limited {
            for work in queue[cursor...] { partial[work.owner] = true }
        }
        var entries = children.enumerated().map { index, url in
            DiskUsageEntry(url: url, bytes: sizes[index], isDirectory: directories[index], partial: partial[index])
        }
        entries.sort { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        largest.sort { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
        return DiskUsageResult(root: root, entries: entries, largestFiles: Array(largest.prefix(20)), visitedCount: visited, inaccessibleCount: inaccessible, excludedCount: excluded, limited: limited)
    }
}
