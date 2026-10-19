import Observation
import SkimCore
import SwiftUI

/// 一次导出的选项（每个打开的视频一份）。各步骤的具体设置用“剪切 / 音量 / 字幕”标签里的。
@MainActor
@Observable
final class ExportAllController {
    var useCut = true
    var useVolume = true
    var useSubtitles = false
    var replaceOriginal = false
}

/// 一次导出面板：剪切 → 统一音量 → 加字幕 → 复制元数据，只生成一个文件。
struct ExportAllPanel: View {
    let player: PlayerController
    let cut: CutController
    let volume: VolumeController
    let subtitles: SubtitleController
    @Bindable var options: ExportAllController
    @Bindable var model: AppModel
    @State private var confirmingReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("把勾选的步骤一次做完，只生成一个新文件（原文件不变）。每一步的具体设置在对应的标签里。")
                .font(.caption)
                .foregroundStyle(.secondary)
            cutRow
            volumeRow
            subtitleRow
            Divider()
            HStack(spacing: 10) {
                Toggle("完成后替换原文件（原文件移到废纸篓）", isOn: $options.replaceOriginal)
                    .help("新文件改用原文件的名字；原文件不会直接删除，可以从废纸篓里放回来")
                Spacer(minLength: 8)
                if let problem {
                    Label(problem, systemImage: "info.circle").foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("将生成：\(previewName)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Button("导出") {
                    if options.replaceOriginal { confirmingReplace = true } else { start() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .task { await subtitles.loadEmbeddedTracks() }
        .alert("导出后替换原文件？", isPresented: $confirmingReplace) {
            Button("导出并替换") { start() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("完成后“\(cut.source.lastPathComponent)”会移到废纸篓，新文件改用它的名字。")
        }
    }

    // MARK: - 步骤

    private var cutsSelection: Bool { options.useCut && !player.selection.isFull }

    private var cutRow: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $options.useCut) {
                if player.selection.isFull {
                    Text("剪切：没有选区（在时间轴上按 I / O 选一段），导出整段")
                } else {
                    Text("剪切 \(Timecode.format(player.selection.start)) – \(Timecode.format(player.selection.end))（\(cut.mode.displayName)）")
                }
            }
            .disabled(player.selection.isFull)
            settingsButton(.cut)
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $options.useVolume) {
                Text(volumeSummary)
            }
            settingsButton(.volume)
        }
    }

    private var volumeSummary: String {
        let o = volume.options
        var s = "统一音量：\(o.preset.displayName)，目标 \(number(o.targetLoudness)) LUFS"
        if o.highpass { s += "，减少喷麦声" }
        if o.declip { s += "，削波修复" }
        if !o.ducks.isEmpty { s += "，压低 \(o.ducks.count) 段" }
        return s
    }

    private var subtitleRow: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $options.useSubtitles) {
                Text(subtitleSummary)
            }
            settingsButton(.subtitles)
        }
    }

    private var subtitleSummary: String {
        let tracks = subtitles.tracks
        if tracks.isEmpty {
            return subtitles.sourceHasSubtitles ? "字幕：去掉全部字幕（\(subtitles.container.displayName)）" : "字幕：还没有字幕"
        }
        return "字幕：\(tracks.count) 条，输出 \(subtitles.container.displayName)"
    }

    private func settingsButton(_ panel: BottomPanel) -> some View {
        Button("设置…") { model.bottomPanel = panel }
            .buttonStyle(.link)
    }

    // MARK: - 导出

    private var job: PipelineJob {
        PipelineJob(
            source: cut.source,
            range: cutsSelection ? player.selectedRange : nil,
            cutMode: cut.mode,
            volume: options.useVolume ? volume.options : nil,
            subtitles: options.useSubtitles ? subtitles.pipelineSubtitles : nil,
            outputDirectory: AppSettings.outputDirectory,
            shiftRecordingDate: AppSettings.shiftRecordingDate,
            replaceOriginal: options.replaceOriginal)
    }

    /// 不能导出的原因；nil 表示可以。
    private var problem: String? {
        let job = self.job
        guard job.hasSteps else { return "至少勾选一个步骤。" }
        if let subs = job.subtitles {
            do {
                try SubtitlePlanner.validate(
                    subs.tracks, container: subs.container, cutting: job.range != nil,
                    sourceHasSubtitles: subtitles.sourceHasSubtitles)
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            if subtitles.isBusy { return "正在检测字幕编码…" }
        }
        return nil
    }

    private var previewName: String {
        let ext = job.subtitles?.container.rawValue ?? cut.source.pathExtension.lowercased()
        return (PipelinePlanner.outputFileName(job, extension: ext) as NSString).deletingPathExtension + ".…"
    }

    private func start() {
        model.exportAll(job)
    }

    private func number(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...1)))
    }
}
