import AppKit
import SkimCore
import SwiftUI

/// 设置项的键和读取方法。播放和剪切相关的设置；其余的在 M6 加入。
enum AppSettings {
    static let skimmingEnabledKey = "skimmingEnabled"
    static let skimDwellMillisecondsKey = "skimDwellMilliseconds"
    static let jumpSecondsKey = "jumpSeconds"
    static let defaultCutModeKey = "defaultCutMode"
    /// 默认输出目录；空字符串表示放在原文件旁边。
    static let outputDirectoryKey = "outputDirectoryPath"
    static let shiftRecordingDateKey = "shiftRecordingDate"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            skimmingEnabledKey: PlaybackDefaults.skimmingEnabled,
            skimDwellMillisecondsKey: PlaybackDefaults.skimDwellMilliseconds,
            jumpSecondsKey: PlaybackDefaults.jumpSeconds,
            defaultCutModeKey: CutMode.precise.rawValue,
            outputDirectoryKey: "",
            shiftRecordingDateKey: true,
        ])
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
