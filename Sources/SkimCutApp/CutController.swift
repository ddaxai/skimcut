import Foundation
import Observation
import SkimCore

/// 剪切面板的状态：模式、导出前的提示（实际起点、编码方式、警告）、保存的多个区间。
///
/// 导出前的提示需要 ffprobe（媒体信息只读一次；快速模式还要找关键帧），
/// 只在选区或模式变化后停顿一下才运行，空闲时不启动任何进程。
@MainActor
@Observable
final class CutController {
    struct Summary: Equatable {
        var outputName: String
        var leadInMessage: String?
        var encoderDescription: String?
        var warnings: [String]
        var copiesMetadata: Bool
    }

    /// 原始文件（导出永远用它，不用预览文件）。
    let source: URL
    var mode: CutMode
    private(set) var summary: Summary?
    private(set) var planError: String?
    private(set) var isPlanning = false
    /// 保存的区间（“添加到列表”），全部导出时每个区间生成一个文件。
    private(set) var ranges: [CutRange] = []

    @ObservationIgnored private var info: MediaInfo?

    init(source: URL, mode: CutMode = AppSettings.defaultCutMode) {
        self.source = source
        self.mode = mode
    }

    /// 选区或模式变了：停顿 0.35 秒后重新规划（由视图的 `.task(id:)` 调用，变化时自动取消上一次）。
    func refreshSummary(for range: CutRange) async {
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }
        isPlanning = true
        defer { isPlanning = false }
        do {
            let info = try await mediaInfo()
            let plan = try await CutExporter().plan(
                source: source, info: info, range: range, options: AppSettings.cutOptions(mode: mode))
            guard !Task.isCancelled else { return }
            summary = Summary(
                outputName: plan.output.lastPathComponent,
                leadInMessage: plan.leadInMessage,
                encoderDescription: plan.encoderDescription,
                warnings: plan.warnings,
                copiesMetadata: plan.copiesMetadata)
            planError = nil
        } catch is CancellationError {
        } catch let error as LocalizedError {
            guard !Task.isCancelled else { return }
            summary = nil
            planError = error.errorDescription ?? "\(error)"
        } catch {
            guard !Task.isCancelled else { return }
            summary = nil
            planError = error.localizedDescription
        }
    }

    private func mediaInfo() async throws -> MediaInfo {
        if let info { return info }
        let loaded = try await MediaInfo.probe(source)
        info = loaded
        return loaded
    }

    func addRange(_ range: CutRange) {
        guard range.duration > 0, !ranges.contains(range) else { return }
        ranges.append(range)
    }

    func removeRange(at index: Int) {
        guard ranges.indices.contains(index) else { return }
        ranges.remove(at: index)
    }

    func removeAllRanges() {
        ranges.removeAll()
    }
}
