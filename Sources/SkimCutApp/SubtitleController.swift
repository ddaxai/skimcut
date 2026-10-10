import Foundation
import Observation
import SkimCore

/// 字幕面板的状态：轨道列表（原有轨道 + 拖进来的字幕文件）、输出格式、是否只导出选区。
@MainActor
@Observable
final class SubtitleController {
    /// 原始文件（导出永远用它，不用预览文件）。
    let source: URL
    private(set) var tracks: [SubtitleTrack] = []
    var container: SubtitleContainer = .mp4
    /// 同时只导出当前选区（快速剪切，字幕按实际起点平移）。
    var cutToSelection = false
    private(set) var isLoadingEmbedded = false
    private(set) var message: String?

    @ObservationIgnored private var embeddedLoaded = false
    /// 正在检测编码的轨道。
    private(set) var detecting: Set<UUID> = []

    init(source: URL) {
        self.source = source
    }

    var allowedContainers: [SubtitleContainer] { SubtitlePlanner.allowedContainers(tracks) }
    var warnings: [String] { SubtitlePlanner.warnings(tracks, container: container) }
    var hasBitmapFile: Bool { tracks.contains { !$0.format.isText && !$0.isEmbedded } }

    /// 第一次显示字幕面板时读取源视频里已有的字幕轨道（默认全部保留）。
    func loadEmbeddedTracks() async {
        guard !embeddedLoaded else { return }
        embeddedLoaded = true
        isLoadingEmbedded = true
        defer { isLoadingEmbedded = false }
        do {
            let info = try await MediaInfo.probe(source)
            let embedded = info.subtitleStreams.compactMap(SubtitleTrack.embedded)
            tracks.insert(contentsOf: embedded, at: 0)
            normalizeDefault()
            fixContainer()
        } catch let error as LocalizedError {
            message = error.errorDescription
        } catch {
            message = error.localizedDescription
        }
    }

    /// 添加字幕文件。不支持的文件给出提示。新加的文字字幕在后台检测编码。
    func addFiles(_ urls: [URL]) {
        var rejected: [String] = []
        for url in urls {
            guard let format = SubtitleFormat.detect(url) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            // IDX/SUB：用 .idx 作为输入。
            let input = format == .vobsub ? url.deletingPathExtension().appendingPathExtension("idx") : url
            if tracks.contains(where: { $0.source == .file(input) }) { continue }
            let track = SubtitleTrack(
                source: .file(input), format: format, language: AppSettings.defaultSubtitleLanguage,
                isDefault: !tracks.contains(where: \.isDefault))
            tracks.append(track)
            if format.isText { detectEncoding(track.id, input) }
        }
        fixContainer()
        message = rejected.isEmpty ? nil : "不支持的文件：\(rejected.joined(separator: "、"))（支持 SRT、ASS、SSA、VTT、SUP、IDX/SUB）"
    }

    private func detectEncoding(_ id: UUID, _ url: URL) {
        detecting.insert(id)
        Task { @MainActor [weak self] in
            let charset = (try? await SubtitleEncoding.detect(url)) ?? "unknown"
            guard let self else { return }
            self.detecting.remove(id)
            if let i = self.tracks.firstIndex(where: { $0.id == id }) {
                self.tracks[i].charset = charset
            }
        }
    }

    func remove(_ id: UUID) {
        tracks.removeAll { $0.id == id }
        normalizeDefault()
        fixContainer()
    }

    func move(_ id: UUID, by delta: Int) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard tracks.indices.contains(j) else { return }
        tracks.swapAt(i, j)
    }

    /// 只能有一条默认轨道；再点一次取消。
    func toggleDefault(_ id: UUID) {
        let wasDefault = tracks.first { $0.id == id }?.isDefault ?? false
        for i in tracks.indices { tracks[i].isDefault = !wasDefault && tracks[i].id == id }
    }

    func setLanguage(_ id: UUID, _ code: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].language = code
    }

    func setTitle(_ id: UUID, _ title: String) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].title = title
    }

    func isDetecting(_ id: UUID) -> Bool { detecting.contains(id) }

    /// 生成用的请求；语言统一规范化。
    func job(range: CutRange?) -> SubtitleJob {
        let normalized = tracks.map { t -> SubtitleTrack in
            var t = t
            t.language = SubtitleLanguages.normalize(t.language)
            return t
        }
        return SubtitleJob(
            source: source, tracks: normalized, container: container,
            range: cutToSelection ? range : nil, outputDirectory: AppSettings.outputDirectory,
            copyMetadata: true, shiftRecordingDate: AppSettings.shiftRecordingDate)
    }

    /// 生成前的检查，返回给用户看的问题（nil 表示可以生成）。
    func problem(range: CutRange?) -> String? {
        do {
            try SubtitlePlanner.validate(tracks, container: container, cutting: cutToSelection && range != nil)
        } catch let error as LocalizedError {
            return error.errorDescription
        } catch {
            return error.localizedDescription
        }
        if !detecting.isEmpty { return "正在检测字幕编码…" }
        return nil
    }

    private func normalizeDefault() {
        var seen = false
        for i in tracks.indices where tracks[i].isDefault {
            if seen { tracks[i].isDefault = false }
            seen = true
        }
    }

    /// 有图形字幕时只能输出 MKV。
    private func fixContainer() {
        if !allowedContainers.contains(container) { container = .mkv }
    }
}
