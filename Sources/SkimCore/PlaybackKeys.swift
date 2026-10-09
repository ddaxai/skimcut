import Foundation

/// 播放相关的默认设置（App 的设置界面可以修改）。
public enum PlaybackDefaults {
    public static let skimmingEnabled = true
    /// 鼠标停留多久开始播放（毫秒）。
    public static let skimDwellMilliseconds = 300
    /// Shift+←/→ 跳几秒。
    public static let jumpSeconds = 1.0
}

/// 键盘命令。
public enum PlaybackCommand: Sendable, Equatable {
    case togglePlay
    case shuttleReverse
    case shuttleStop
    case shuttleForward
    case stepBackward
    case stepForward
    case jumpBackward
    case jumpForward
    case zoomIn
    case zoomOut
    /// I：起点设在当前位置。
    case markIn
    /// O：终点设在当前位置。
    case markOut
}

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// 按键 → 命令。字母按 `charactersIgnoringModifiers` 判断（与键盘布局无关），
/// 空格和方向键按 macOS 的虚拟键码判断。
public enum PlaybackKeyMap {
    public static let spaceKeyCode: UInt16 = 49
    public static let leftArrowKeyCode: UInt16 = 123
    public static let rightArrowKeyCode: UInt16 = 124

    public static func command(keyCode: UInt16, characters: String?, modifiers: KeyModifiers) -> PlaybackCommand? {
        let chars = (characters ?? "").lowercased()
        if modifiers.contains(.command) {
            guard modifiers.isDisjoint(with: [.control, .option]) else { return nil }
            switch chars {
            case "=", "+": return .zoomIn
            case "-", "_": return modifiers.contains(.shift) ? nil : .zoomOut
            default: return nil
            }
        }
        guard modifiers.isDisjoint(with: [.control, .option]) else { return nil }
        let shift = modifiers.contains(.shift)
        switch keyCode {
        case leftArrowKeyCode: return shift ? .jumpBackward : .stepBackward
        case rightArrowKeyCode: return shift ? .jumpForward : .stepForward
        case spaceKeyCode: return shift ? nil : .togglePlay
        default: break
        }
        guard !shift else { return nil }
        switch chars {
        case "j": return .shuttleReverse
        case "k": return .shuttleStop
        case "l": return .shuttleForward
        case "i": return .markIn
        case "o": return .markOut
        default: return nil
        }
    }
}

/// 时间轴刻度。
public enum TimelineTicks {
    /// 可选的刻度间隔（秒）。
    public static let steps: [Double] = [
        0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200,
    ]

    /// 相邻刻度至少相隔 `minimumPixels` 像素时的最小间隔。
    public static func interval(pixelsPerSecond: Double, minimumPixels: Double) -> Double {
        let wanted = minimumPixels / max(pixelsPerSecond, 1e-9)
        return steps.first { $0 >= wanted } ?? (wanted / 3600).rounded(.up) * 3600
    }

    /// 刻度标签：整秒显示 `M:SS` 或 `H:MM:SS`，否则带一位小数。
    public static func label(_ seconds: Double, interval: Double) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) / 60) % 60
        let s = total - Double(h * 3600 + m * 60)
        let secText: String
        if interval < 1 {
            secText = String(format: "%04.1f", s)
        } else {
            secText = String(format: "%02d", Int(s.rounded()))
        }
        if h > 0 { return String(format: "%d:%02d:", h, m) + secText }
        return String(format: "%d:", m) + secText
    }
}
