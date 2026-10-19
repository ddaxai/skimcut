import AppKit
import SkimCore
import SwiftUI

/// 设置项的键和读取方法（AGENTS.md 4.7 的全部设置项：默认输出位置、skimming、默认目标响度、默认剪切模式、默认字幕语言）。
enum AppSettings {
    static let skimmingEnabledKey = "skimmingEnabled"
    static let skimDwellMillisecondsKey = "skimDwellMilliseconds"
    static let jumpSecondsKey = "jumpSeconds"
    static let defaultCutModeKey = "defaultCutMode"
    /// 默认输出目录；空字符串表示放在原文件旁边。
    static let outputDirectoryKey = "outputDirectoryPath"
    static let shiftRecordingDateKey = "shiftRecordingDate"
    static let defaultSubtitleLanguageKey = "defaultSubtitleLanguage"
    static let autoDetectLoudnessKey = "autoDetectLoudness"
    static let targetLoudnessKey = "targetLoudness"
    static let truePeakKey = "truePeak"
    static let loudnessPresetKey = "loudnessPreset"
    static let burstMarginKey = "burstMargin"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            skimmingEnabledKey: PlaybackDefaults.skimmingEnabled,
            skimDwellMillisecondsKey: PlaybackDefaults.skimDwellMilliseconds,
            jumpSecondsKey: PlaybackDefaults.jumpSeconds,
            defaultCutModeKey: CutMode.precise.rawValue,
            outputDirectoryKey: "",
            shiftRecordingDateKey: true,
            defaultSubtitleLanguageKey: SubtitleLanguages.defaultCode,
            autoDetectLoudnessKey: true,
            targetLoudnessKey: NormalizeOptions.defaultTarget,
            truePeakKey: NormalizeOptions.defaultTruePeak,
            loudnessPresetKey: LoudnessPreset.unify.rawValue,
            burstMarginKey: LoudnessBursts.defaultMargin,
        ])
    }

    /// 打开视频时在后台检测一次响度。
    static var autoDetectLoudness: Bool {
        UserDefaults.standard.bool(forKey: autoDetectLoudnessKey)
    }

    /// 新打开的视频和批量窗口使用的默认音量选项（局部压低和修复选项每次重新选）。
    /// 没有设置过（或者读的时候默认值还没注册）时用 -16 LUFS / -1.5 dBTP。
    static var defaultNormalizeOptions: NormalizeOptions {
        let d = UserDefaults.standard
        let target = (d.object(forKey: targetLoudnessKey) as? Double).flatMap { (-30.0...(-10.0)).contains($0) ? $0 : nil }
        let peak = (d.object(forKey: truePeakKey) as? Double).flatMap { (-6.0...0.0).contains($0) ? $0 : nil }
        return NormalizeOptions(
            targetLoudness: target ?? NormalizeOptions.defaultTarget,
            truePeak: peak ?? NormalizeOptions.defaultTruePeak,
            preset: LoudnessPreset(rawValue: d.string(forKey: loudnessPresetKey) ?? "") ?? .unify)
    }

    /// 爆音阈值：短时响度超过“整体响度 + 这么多 LU”。
    static var burstMargin: Double {
        let v = UserDefaults.standard.double(forKey: burstMarginKey)
        return v > 0 ? v : LoudnessBursts.defaultMargin
    }

    static var defaultCutMode: CutMode {
        CutMode(rawValue: UserDefaults.standard.string(forKey: defaultCutModeKey) ?? "") ?? .precise
    }

    /// 设置的输出目录；没有设置或目录不存在时为 nil（放在原文件旁边）。
    static var outputDirectory: URL? {
        let path = UserDefaults.standard.string(forKey: outputDirectoryKey) ?? ""
        var isDirectory: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 新加字幕的默认语言（ISO 639-2）。
    static var defaultSubtitleLanguage: String {
        SubtitleLanguages.normalize(UserDefaults.standard.string(forKey: defaultSubtitleLanguageKey) ?? SubtitleLanguages.defaultCode)
    }

    static var shiftRecordingDate: Bool {
        UserDefaults.standard.bool(forKey: shiftRecordingDateKey)
    }

    /// 当前设置下的剪切选项。
    static func cutOptions(mode: CutMode) -> CutOptions {
        CutOptions(mode: mode, outputDirectory: outputDirectory, copyMetadata: true, shiftRecordingDate: shiftRecordingDate)
    }

    static var skimmingEnabled: Bool {
        UserDefaults.standard.bool(forKey: skimmingEnabledKey)
    }

    /// 停留时间（秒）。
    static var skimDwell: Double {
        Double(max(50, UserDefaults.standard.integer(forKey: skimDwellMillisecondsKey))) / 1000
    }

    static var jumpSeconds: Double {
        let v = UserDefaults.standard.double(forKey: jumpSecondsKey)
        return v > 0 ? v : PlaybackDefaults.jumpSeconds
    }
}

struct SettingsView: View {
    @AppStorage(AppSettings.skimmingEnabledKey) private var skimmingEnabled = PlaybackDefaults.skimmingEnabled
    @AppStorage(AppSettings.skimDwellMillisecondsKey) private var dwellMilliseconds = PlaybackDefaults.skimDwellMilliseconds
    @AppStorage(AppSettings.jumpSecondsKey) private var jumpSeconds = PlaybackDefaults.jumpSeconds
    @AppStorage(AppSettings.defaultCutModeKey) private var defaultCutMode = CutMode.precise.rawValue
    @AppStorage(AppSettings.outputDirectoryKey) private var outputDirectory = ""
    @AppStorage(AppSettings.shiftRecordingDateKey) private var shiftRecordingDate = true
    @AppStorage(AppSettings.defaultSubtitleLanguageKey) private var defaultSubtitleLanguage = SubtitleLanguages.defaultCode
    @AppStorage(AppSettings.autoDetectLoudnessKey) private var autoDetectLoudness = true
    @AppStorage(AppSettings.targetLoudnessKey) private var targetLoudness = NormalizeOptions.defaultTarget
    @AppStorage(AppSettings.truePeakKey) private var truePeak = NormalizeOptions.defaultTruePeak
    @AppStorage(AppSettings.loudnessPresetKey) private var loudnessPreset = LoudnessPreset.unify.rawValue
    @AppStorage(AppSettings.burstMarginKey) private var burstMargin = LoudnessBursts.defaultMargin
    @State private var cacheCleared = false

    var body: some View {
        Form {
            Section("Skimming") {
                Toggle("鼠标悬停在时间轴上时预览画面（skimming）", isOn: $skimmingEnabled)
                Stepper(value: $dwellMilliseconds, in: 100...3000, step: 50) {
                    Text("停留 \(dwellMilliseconds) 毫秒后开始播放")
                }
                .disabled(!skimmingEnabled)
            }
            Section("剪切") {
                Picker("默认剪切模式", selection: $defaultCutMode) {
                    ForEach(CutMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                LabeledContent("默认输出位置") {
                    HStack {
                        Text(outputDirectory.isEmpty ? "原文件旁边" : (outputDirectory as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("选择…") { chooseOutputDirectory() }
                        if !outputDirectory.isEmpty {
                            Button("恢复为原文件旁边") { outputDirectory = "" }
                        }
                    }
                }
                Toggle("剪出的片段：录制时间 = 原录制时间 + 剪切起点", isOn: $shiftRecordingDate)
            }
            Section("字幕") {
                Picker("新加字幕的默认语言", selection: $defaultSubtitleLanguage) {
                    ForEach(SubtitleLanguages.common, id: \.code) { item in
                        Text("\(item.name)（\(item.code)）").tag(item.code)
                    }
                }
            }
            Section("音量") {
                Toggle("打开视频时在后台检测响度", isOn: $autoDetectLoudness)
                Stepper(value: $targetLoudness, in: -30...(-10), step: 0.5) {
                    Text("默认目标响度 \(targetLoudness.formatted(.number.precision(.fractionLength(0...1)))) LUFS")
                }
                Stepper(value: $truePeak, in: -6...0, step: 0.5) {
                    Text("默认真峰值上限 \(truePeak.formatted(.number.precision(.fractionLength(0...1)))) dBTP")
                }
                Picker("默认强度", selection: $loudnessPreset) {
                    ForEach(LoudnessPreset.allCases, id: \.rawValue) { preset in
                        Text(preset.displayName).tag(preset.rawValue)
                    }
                }
                Stepper(value: $burstMargin, in: 3...30, step: 1) {
                    Text("爆音：比整体响度高 \(Int(burstMargin)) LU 以上")
                }
                LabeledContent("检测结果缓存") {
                    Button(cacheCleared ? "已清除" : "清除") {
                        LoudnessCache.shared.removeAll()
                        cacheCleared = true
                    }
                    .disabled(cacheCleared)
                }
            }
            Section("键盘") {
                Stepper(value: $jumpSeconds, in: 0.5...60, step: 0.5) {
                    Text("Shift + ←/→ 跳 \(jumpSeconds.formatted(.number.precision(.fractionLength(0...1)))) 秒")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url.path
        }
    }
}
