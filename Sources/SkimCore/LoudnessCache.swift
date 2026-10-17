import Foundation

/// 响度检测结果的磁盘缓存，按“路径 + 大小 + 修改时间”区分；文件改过之后自动失效。
///
/// 每个文件一个 JSON（短时响度序列也在里面，改爆音阈值时不用重新检测）。
/// 条目超过 `maxEntries` 时删除最久没用过的。
public final class LoudnessCache: @unchecked Sendable {
    public struct Key: Sendable, Hashable, Codable {
        public var path: String
        public var size: Int64
        public var modified: Double

        public init(path: String, size: Int64, modified: Double) {
            self.path = path
            self.size = size
            self.modified = modified
        }

        /// 读取文件的大小和修改时间；文件不存在时为 nil。
        public static func of(_ url: URL) -> Key? {
            let path = url.standardizedFileURL.path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  let date = attrs[.modificationDate] as? Date
            else { return nil }
            return Key(path: path, size: size, modified: date.timeIntervalSince1970)
        }

        /// 缓存文件名：FNV-1a 64 位哈希（不需要加密强度，只要分散）。
        var fileName: String {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in "\(path)\u{0}\(size)\u{0}\(modified)".utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            return String(format: "%016llx.json", hash)
        }
    }

    private struct Entry: Codable {
        var key: Key
        var analysis: LoudnessAnalysis
    }

    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("SkimCut/loudness", isDirectory: true)
    }

    public static let shared = LoudnessCache()

    public let directory: URL
    public let maxEntries: Int
    private let lock = NSLock()

    public init(directory: URL = LoudnessCache.defaultDirectory, maxEntries: Int = 300) {
        self.directory = directory
        self.maxEntries = maxEntries
    }

    public func analysis(for url: URL) -> LoudnessAnalysis? {
        guard let key = Key.of(url) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let file = directory.appendingPathComponent(key.fileName)
        guard let data = FileManager.default.contents(atPath: file.path),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.key == key
        else { return nil }
        // 记录“最近用过”，清理时按修改时间删最旧的。
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return entry.analysis
    }

    public func store(_ analysis: LoudnessAnalysis, for url: URL) {
        guard let key = Key.of(url), let data = try? JSONEncoder().encode(Entry(key: key, analysis: analysis)) else { return }
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(key.fileName), options: .atomic)
        prune()
    }

    /// 删除全部缓存。
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles),
            files.count > maxEntries
        else { return }
        func date(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let sorted = files.sorted { date($0) < date($1) }
        for url in sorted.prefix(files.count - maxEntries) {
            try? fm.removeItem(at: url)
        }
    }
}
