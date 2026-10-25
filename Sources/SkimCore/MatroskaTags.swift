import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// MKV 的全局标签（`mkvextract tags` 输出里没有 TrackUID / EditionUID / ChapterUID / AttachmentUID 的 `<Tag>`）。
///
/// `mkvpropedit --tags global:文件` 会替换全部全局标签，所以改描述时要先读出原有的全局标签，
/// 只改 DESCRIPTION，其他的原样写回；轨道标签不受影响。
public struct MatroskaGlobalTags: Sendable, Equatable {
    /// 按原来的顺序。
    public var entries: [(name: String, value: String)]

    public init(entries: [(name: String, value: String)] = []) {
        self.entries = entries
    }

    public static func == (a: MatroskaGlobalTags, b: MatroskaGlobalTags) -> Bool {
        a.entries.map(\.name) == b.entries.map(\.name) && a.entries.map(\.value) == b.entries.map(\.value)
    }

    public subscript(name: String) -> String? {
        get { entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        set {
            if let i = entries.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                if let newValue {
                    entries[i].value = newValue
                } else {
                    entries.remove(at: i)
                }
            } else if let newValue {
                entries.append((name, newValue))
            }
        }
    }

    /// 描述：DESCRIPTION，没有时用 COMMENT。
    public var description: String? { self["DESCRIPTION"] ?? self["COMMENT"] }

    /// 设置描述（空字符串表示删除）。原来有 COMMENT 的也一起改，免得播放器显示旧的。
    public mutating func setDescription(_ text: String) {
        let value: String? = text.isEmpty ? nil : text
        self["DESCRIPTION"] = value
        if self["COMMENT"] != nil { self["COMMENT"] = value }
    }

    /// 解析 `mkvextract 文件 tags -` 的 XML，只取全局标签。
    public static func parse(_ data: Data) -> MatroskaGlobalTags {
        let delegate = Parser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return MatroskaGlobalTags(entries: delegate.entries)
    }

    /// 给 `mkvpropedit --tags global:文件` 用的 XML。
    public var xml: String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Tags>\n  <Tag>\n    <Targets />\n"
        for e in entries {
            s += "    <Simple><Name>\(Self.escape(e.name))</Name><String>\(Self.escape(e.value))</String></Simple>\n"
        }
        s += "  </Tag>\n</Tags>\n"
        return s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 只收集全局 `<Tag>` 里最外层的 `<Simple>`（嵌套的子标签忽略）。
    private final class Parser: NSObject, XMLParserDelegate {
        var entries: [(name: String, value: String)] = []
        private var path: [String] = []
        private var tagEntries: [(name: String, value: String)] = []
        private var tagIsGlobal = true
        private var name = ""
        private var value = ""
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(element)
            text = ""
            if element == "Tag" {
                tagEntries = []
                tagIsGlobal = true
            } else if element.hasSuffix("UID"), path.dropLast().last == "Targets" {
                tagIsGlobal = false
            } else if element == "Simple", path.count == 3 {
                name = ""
                value = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            // Tags / Tag / Simple / Name：最外层 Simple 的 Name 和 String 在第 4 层下面。
            if path.count == 4, path[2] == "Simple" {
                if element == "Name" { name = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                if element == "String" { value = text }
            } else if element == "Simple", path.count == 3, !name.isEmpty {
                tagEntries.append((name, value))
            } else if element == "Tag", path.count == 2, tagIsGlobal {
                entries += tagEntries
            }
            path.removeLast()
            text = ""
        }
    }
}
