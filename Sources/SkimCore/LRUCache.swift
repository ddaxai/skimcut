import Foundation

/// 同时限制条目数和总开销（例如字节数）的 LRU 缓存。不是线程安全的，由调用方保证串行访问。
///
/// 淘汰时线性查找最久没用的条目；缩略图缓存只有几百条，这样比维护链表更简单。
public struct LRUCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var lastUse: UInt64
    }

    public let countLimit: Int
    public let costLimit: Int
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public private(set) var totalCost = 0

    public init(countLimit: Int, costLimit: Int = .max) {
        self.countLimit = max(1, countLimit)
        self.costLimit = max(1, costLimit)
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// 读取并标记为最近使用。
    public mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.value
    }

    /// 只看不标记。
    public func peek(_ key: Key) -> Value? { entries[key]?.value }

    public func contains(_ key: Key) -> Bool { entries[key] != nil }

    /// 写入；开销超过上限的单个条目不缓存。返回被淘汰的键。
    @discardableResult
    public mutating func insert(_ value: Value, for key: Key, cost: Int = 1) -> [Key] {
        let cost = max(0, cost)
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
        guard cost <= costLimit else { return [] }
        clock &+= 1
        entries[key] = Entry(value: value, cost: cost, lastUse: clock)
        totalCost += cost
        var evicted: [Key] = []
        while entries.count > countLimit || totalCost > costLimit {
            guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key else { break }
            if let removed = entries.removeValue(forKey: oldest) { totalCost -= removed.cost }
            evicted.append(oldest)
        }
        return evicted
    }

    @discardableResult
    public mutating func remove(_ key: Key) -> Value? {
        guard let removed = entries.removeValue(forKey: key) else { return nil }
        totalCost -= removed.cost
        return removed.value
    }

    public mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
    }
}
