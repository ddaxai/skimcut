import ArgumentParser
import Foundation
import SkimCore

@main
struct SkimCutCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skimcut",
        abstract: "SkimCut 命令行工具：提供 SkimCore 的全部功能。",
        version: SkimCoreInfo.version,
        subcommands: [Tools.self, Probe.self, Preview.self]
    )
}

/// `skimcut tools`：列出每个外部工具的路径和版本。
struct Tools: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "检查外部工具的位置和版本。")

    @Flag(help: "以 JSON 格式输出。")
    var json = false

    @Flag(help: "缺少任何工具时以非零状态退出。")
    var strict = false

    func run() async throws {
        let statuses = await ToolInventory.check()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(statuses), as: UTF8.self))
        } else {
            for s in statuses {
                let name = s.tool.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)
                if let path = s.path {
                    print("\(name)\(s.version ?? "?")\t\(path)")
                } else {
                    print("\(name)未找到\t安装：\(s.tool.installHint)")
                }
            }
        }
        if strict, statuses.contains(where: { !$0.isAvailable }) {
            throw ExitCode(1)
        }
    }
}

/// `skimcut probe <文件>`：显示媒体信息。
struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "显示视频的时长、容器和各条流的信息（ffprobe）。")

    @Argument(help: "视频文件。", transform: { URL(fileURLWithPath: $0) })
    var file: URL

    @Flag(help: "输出 ffprobe 的原始 JSON。")
    var json = false

    func run() async throws {
        if json {
            let command = try ToolLocator.shared.command(.ffprobe, MediaInfo.probeArguments(for: file))
            print(try await ToolRunner().output(command), terminator: "")
            return
        }
        let info = try await MediaInfo.probe(file)
        print("容器：\(info.formatName)")
        print("时长：\(info.bestDuration.map(Timecode.format) ?? "未知")")
        for s in info.streams {
            var parts = ["#\(s.index)", s.codecType, s.codecName ?? "?"]
            if let tag = s.codecTagString, !tag.hasPrefix("[") { parts.append("tag=\(tag)") }
            if let w = s.width, let h = s.height { parts.append("\(w)x\(h)") }
            if let fmt = s.pixelFormat { parts.append(fmt) }
            if let fps = s.frameRate, s.isVideo { parts.append(String(format: "%.3f fps", fps)) }
            if s.isHDR { parts.append("HDR") }
            if s.isAttachedPicture { parts.append("封面图") }
            if let lang = s.language { parts.append("lang=\(lang)") }
            print(parts.joined(separator: "  "))
        }
        let strategy = try PreviewPlanner.strategy(for: info, nativelyPlayable: PreviewPlanner.guessNativelyPlayable(info))
        print("预览方式（推测）：\(strategy.rawValue)")
    }
}

/// `skimcut preview <文件>`：生成 App 用的预览文件（转封装或低分辨率代理）。
struct Preview: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "生成预览文件：能转封装就 -c copy，否则生成低分辨率代理。")

    enum StrategyOption: String, ExpressibleByArgument, CaseIterable {
        case auto, remux, proxy
    }

    @Argument(help: "视频文件。", transform: { URL(fileURLWithPath: $0) })
    var file: URL

    @Option(name: .shortAndLong, help: "输出文件（.mp4）。默认放在原文件旁边：原名_preview.mp4。",
            transform: { URL(fileURLWithPath: $0) })
    var output: URL?

    @Option(help: "预览方式：auto、remux、proxy。")
    var strategy: StrategyOption = .auto

    @Option(help: "代理的视频编码器：h264_videotoolbox 或 libx264。")
    var encoder: String = PreviewEncoder.platformDefault.rawValue

    func run() async throws {
        guard let enc = PreviewEncoder(rawValue: encoder) else {
            throw ValidationError("不支持的编码器：\(encoder)")
        }
        let info = try await MediaInfo.probe(file)
        let chosen: PreviewStrategy
        switch strategy {
        case .auto:
            chosen = try PreviewPlanner.strategy(for: info, nativelyPlayable: PreviewPlanner.guessNativelyPlayable(info))
        case .remux:
            guard let v = info.videoStream, PreviewPlanner.canRemux(video: v, audio: info.audioStreams.first) else {
                throw ValidationError("这个文件不能直接转封装（需要 H.264/HEVC + AAC），请用 --strategy proxy。")
            }
            chosen = .remux
        case .proxy:
            guard info.videoStream != nil else { throw PreviewError.noVideoStream }
            chosen = .proxy
        }
        guard chosen != .native else {
            print("AVPlayer 应该可以直接播放，不需要预览文件。如果确实打不开，加 --strategy remux 或 proxy。")
            return
        }
        let out = output ?? file.deletingLastPathComponent()
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent + "_preview.mp4")
        guard !FileManager.default.fileExists(atPath: out.path) else {
            throw ValidationError("输出文件已存在：\(out.path)")
        }
        print("方式：\(chosen.rawValue)  →  \(out.path)")
        let last = LastPercent()
        try await PreviewBuilder(encoder: enc).build(source: file, info: info, strategy: chosen, output: out) { p in
            if let p, last.update(Int(p * 100)) {
                FileHandle.standardError.write(Data("\r进度 \(Int(p * 100))%".utf8))
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))
        print("完成")
    }
}

/// 只在百分比变化时打印。
private final class LastPercent: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1

    func update(_ new: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard new != value else { return false }
        value = new
        return true
    }
}
