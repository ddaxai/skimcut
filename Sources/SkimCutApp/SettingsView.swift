import SkimCore
import SwiftUI

/// 设置项的键和读取方法。M1 只有播放相关的设置，其余的在 M6 加入。
enum AppSettings {
    static let skimmingEnabledKey = "skimmingEnabled"
    static let skimDwellMillisecondsKey = "skimDwellMilliseconds"
    static let jumpSecondsKey = "jumpSeconds"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            skimmingEnabledKey: PlaybackDefaults.skimmingEnabled,
            skimDwellMillisecondsKey: PlaybackDefaults.skimDwellMilliseconds,
            jumpSecondsKey: PlaybackDefaults.jumpSeconds,
        ])
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

    var body: some View {
        Form {
            Section("Skimming") {
                Toggle("鼠标悬停在时间轴上时预览画面（skimming）", isOn: $skimmingEnabled)
                Stepper(value: $dwellMilliseconds, in: 100...3000, step: 50) {
                    Text("停留 \(dwellMilliseconds) 毫秒后开始播放")
                }
                .disabled(!skimmingEnabled)
            }
            Section("键盘") {
                Stepper(value: $jumpSeconds, in: 0.5...60, step: 0.5) {
                    Text("Shift + ←/→ 跳 \(jumpSeconds.formatted(.number.precision(.fractionLength(0...1)))) 秒")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
