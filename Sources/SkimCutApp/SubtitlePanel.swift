import AppKit
import SkimCore
import SwiftUI
import UniformTypeIdentifiers

/// 软字幕面板：字幕轨道列表（原有轨道 + 拖进来的字幕文件）、语言 / 标题 / 默认轨道、输出格式、生成。
struct SubtitlePanel: View {
    let player: PlayerController
    @Bindable var subtitles: SubtitleController
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button("添加字幕…") { chooseFiles() }
                    .help("也可以把 SRT、ASS、SSA、VTT、SUP、IDX/SUB 文件直接拖进窗口")

                Picker("输出", selection: $subtitles.container) {
                    ForEach(SubtitleContainer.allCases, id: \.self) { c in
                        Text(c.displayName).tag(c)
                            .disabled(!subtitles.allowedContainers.contains(c))
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("MP4：文字字幕转成 mov_text，兼容性最好；MKV：保留原格式和样式，图形字幕只能用 MKV")

                Toggle("只导出当前选区（快速剪切）", isOn: $subtitles.cutToSelection)
                    .disabled(player.selection.isFull)
                    .help("同时把当前选区剪出来；字幕时间会减去实际起点")

                Spacer(minLength: 8)

                Button("生成") {
                    model.exportSubtitles(subtitles.job(range: player.selectedRange))
                }
                .disabled(subtitles.problem(range: player.selectedRange) != nil)
                .help("视频和音频直接复制，不重新编码；原文件不变")
            }

            notices

            if subtitles.isLoadingEmbedded {
                ProgressView().controlSize(.small)
            } else if subtitles.tracks.isEmpty {
                Text("还没有字幕。把字幕文件拖进窗口，或者点“添加字幕…”。")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                trackList
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .task { await subtitles.loadEmbeddedTracks() }
    }

    @ViewBuilder
    private var notices: some View {
        let problem = subtitles.problem(range: player.selectedRange)
        VStack(alignment: .leading, spacing: 2) {
            if let message = subtitles.message {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let problem, !subtitles.tracks.isEmpty {
                Label(problem, systemImage: "info.circle").foregroundStyle(.secondary)
            }
            if subtitles.hasBitmapFile {
                Label("有图形字幕（SUP、IDX/SUB），只能输出 MKV。", systemImage: "info.circle").foregroundStyle(.secondary)
            }
            ForEach(subtitles.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if subtitles.cutToSelection, !player.selection.isFull {
                Text("只导出 \(Timecode.format(player.selection.start)) – \(Timecode.format(player.selection.end))；快速剪切会从起点之前最近的关键帧开始，字幕按实际起点平移。")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    private var trackList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(subtitles.tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        track: track, index: index, count: subtitles.tracks.count,
                        detecting: subtitles.isDetecting(track.id), subtitles: subtitles)
                }
            }
        }
        .frame(maxHeight: 150)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SubtitleFormat.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            subtitles.addFiles(panel.urls)
        }
    }
}

private struct TrackRow: View {
    let track: SubtitleTrack
    let index: Int
    let count: Int
    let detecting: Bool
    let subtitles: SubtitleController

    @State private var language = ""
    @State private var title = ""

    var body: some View {
        HStack(spacing: 8) {
            Button {
                subtitles.toggleDefault(track.id)
            } label: {
                Image(systemName: track.isDefault ? "star.fill" : "star")
                    .foregroundStyle(track.isDefault ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(track.isDefault ? "默认轨道（再点一次取消）" : "设为默认轨道")

            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 230, alignment: .leading)

            TextField("语言", text: $language)
                .textFieldStyle(.roundedBorder)
                .frame(width: 56)
                .onSubmit { subtitles.setLanguage(track.id, language) }
                .help("ISO 639-2 语言代码，例如 chi、eng、jpn")
            Menu {
                ForEach(SubtitleLanguages.common, id: \.code) { item in
                    Button("\(item.name)（\(item.code)）") {
                        language = item.code
                        subtitles.setLanguage(track.id, item.code)
                    }
                }
            } label: {
                Image(systemName: "globe")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()

            TextField("标题（可选）", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
                .onSubmit { subtitles.setTitle(track.id, title) }

            Spacer(minLength: 0)

            Button { subtitles.move(track.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
            Button { subtitles.move(track.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == count - 1)
            Button { subtitles.remove(track.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(track.isEmbedded ? "不保留这条原有轨道" : "去掉这个字幕文件")
        }
        .onAppear {
            language = track.language
            title = track.title
        }
        .onChange(of: language) { subtitles.setLanguage(track.id, language) }
        .onChange(of: title) { subtitles.setTitle(track.id, title) }
    }

    private var name: String {
        switch track.source {
        case .file(let url): return url.lastPathComponent
        case .embedded(let index): return "原有轨道 #\(index)"
        }
    }

    private var detail: String {
        var parts = [track.format.displayName]
        if track.isEmbedded { parts.append("源视频里已有") }
        if detecting {
            parts.append("正在检测编码…")
        } else if let charset = track.charset {
            parts.append(SubtitleEncoding.displayName(charset))
        }
        return parts.joined(separator: " · ")
    }
}
