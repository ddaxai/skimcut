import Foundation

/// 查找外部工具的完整路径。
///
/// 从 Finder 启动的 App 拿不到终端的 PATH，所以按固定顺序查找：
/// `/opt/homebrew/bin` → `/usr/local/bin` → `/usr/bin` → `~/.local/bin`，
/// 最后用登录 shell 的 `command -v` 兜底（macOS 用 `/bin/zsh -lc`，Linux 用 `/bin/sh -lc`）。
/// 查找结果会缓存。
public final class ToolLocator: @unchecked Sendable {
    public static let shared = ToolLocator()

    public let searchDirectories: [URL]
    public let useShellFallback: Bool

    private let lock = NSLock()
    private var cache: [String: URL] = [:]

    public init(
        searchDirectories: [URL] = ToolLocator.defaultSearchDirectories(),
        useShellFallback: Bool = true
    ) {
        self.searchDirectories = searchDirectories
        self.useShellFallback = useShellFallback
    }

    public static func defaultSearchDirectories(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            home.appendingPathComponent(".local/bin", isDirectory: true),
        ]
    }

    /// 兜底时使用的登录 shell。
    public static var fallbackShell: URL {
        #if os(macOS)
        URL(fileURLWithPath: "/bin/zsh")
        #else
        URL(fileURLWithPath: "/bin/sh")
        #endif
    }

    public func locate(_ tool: Tool) -> URL? {
        locate(executableNamed: tool.executableName)
    }

    public func locate(executableNamed name: String) -> URL? {
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let found = search(name) else { return nil }
        lock.lock()
        cache[name] = found
        lock.unlock()
        return found
    }

    /// 找不到时抛出 `ToolError.toolNotFound`。
    public func require(_ tool: Tool) throws -> URL {
        guard let url = locate(tool) else { throw ToolError.toolNotFound(tool) }
        return url
    }

    /// 外部工具统一使用的 UTF-8 locale。
    /// 从 Finder 启动的 App 没有 LANG；在 C locale 下 mkvpropedit 会丢掉参数里的中文。
    public static var utf8Locale: String {
        #if os(macOS)
        "en_US.UTF-8"
        #else
        "C.UTF-8"
        #endif
    }

    /// 生成调用某个工具的 `Command`。
    /// - 总是设置 `LC_ALL` 为 UTF-8 locale，保证中文文件名和标题不被破坏；
    /// - ffmpeg-normalize 会自动带上 `FFMPEG_PATH`（ffmpeg 的完整路径）。
    public func command(_ tool: Tool, _ arguments: [String]) throws -> Command {
        var cmd = Command(executable: try require(tool), arguments: arguments)
        cmd.environment["LC_ALL"] = Self.utf8Locale
        if tool == .ffmpegNormalize {
            cmd.environment["FFMPEG_PATH"] = try require(.ffmpeg).path
        }
        return cmd
    }

    /// 清空缓存（例如用户刚安装了工具）。
    public func resetCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private func search(_ name: String) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories {
            let candidate = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), !isDir.boolValue,
               fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        guard useShellFallback else { return nil }
        return shellLookup(name)
    }

    /// `shell -lc 'command -v "$1"' shell NAME`：名字作为位置参数传入，不拼接进脚本。
    private func shellLookup(_ name: String) -> URL? {
        let shell = Self.fallbackShell
        guard FileManager.default.isExecutableFile(atPath: shell.path) else { return nil }
        let process = Process()
        process.executableURL = shell
        process.arguments = ["-lc", #"command -v "$1""#, shell.lastPathComponent, name]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        // `command -v` 对 alias / 函数会返回非路径文字，只接受绝对路径。
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
