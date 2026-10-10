import Foundation

/// 输出文件的命名：`原名_cut_01m23.456s-01m35.456s.mp4`，重名时加序号，从不覆盖。
public enum OutputNaming {
    /// 文件名里的时间：`01m23.456s`；一小时以上 `1h02m03.456s`。
    public static func timeTag(_ seconds: Double) -> String {
        let millis = Int64((max(0, seconds) * 1000).rounded())
        let ms = millis % 1000
        let totalSeconds = millis / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        let core = String(format: "%02lldm%02lld.%03llds", m, s, ms)
        return h > 0 ? String(format: "%lldh", h) + core : core
    }

    /// `原名_cut_起点-终点.扩展名`
    public static func cutFileName(source: URL, range: CutRange, extension ext: String) -> String {
        let base = source.deletingPathExtension().lastPathComponent
        return "\(base)_cut_\(timeTag(range.start))-\(timeTag(range.end)).\(ext)"
    }

    /// 文件已存在时依次尝试 `名字_2.扩展名`、`名字_3.扩展名`……
    public static func uniqueURL(_ url: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        guard exists(url) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base)_\(n)" : "\(base)_\(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}
